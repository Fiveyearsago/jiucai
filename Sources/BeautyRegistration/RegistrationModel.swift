import AppKit
import Combine
import RegistrationCore

@MainActor
final class RegistrationModel: ObservableObject {
    typealias TransportFactory = (ProxyEntry?, TimeInterval) throws -> NativeHTTPClient.Transport
    typealias ProxyTest = (ProxyEntry, ProxyConfiguration) async -> ProxyManager.TestResult

    @Published var configuration = TaskConfiguration()
    @Published var proxyConfiguration = ProxyConfiguration()
    @Published var proxyTestConcurrency = ProxyManager.defaultBatchConcurrency
    @Published private(set) var isTestingProxies = false
    @Published private(set) var proxyTestResults: [UUID: ProxyManager.TestResult] = [:]
    @Published private(set) var proxyTestPending: Set<UUID> = []
    @Published private(set) var proxyTestsCompleted = 0
    @Published private(set) var proxyTestsTotal = 0
    @Published private(set) var proxyTestsDiscarded = 0
    private let rememberedPassword: RememberedPassword
    private var passwordObserver: AnyCancellable?
    private var monitorObserver: AnyCancellable?
    var password: String {
        get { rememberedPassword.value }
        set { rememberedPassword.value = newValue }
    }
    var passwordStatus: String { rememberedPassword.status }
    @Published var records: [AccountRecord] = []
    @Published var logs: [String] = []
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var phase = "准备开始"
    @Published var detail = "填写注册信息，请求验证码后注册账号。"
    @Published var currentUsername = ""
    @Published var step = 0
    @Published var tab = "registration"
    @Published var manualCode = ""
    @Published var formUsername = ""
    @Published var formEmail = ""
    @Published var autoReadMailbox = true
    @Published private(set) var isManualFlow = false
    @Published private(set) var waitingForCode = false
    @Published private(set) var verificationSent = false
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var siteStatusDescription = "尚未检查"
    @Published private(set) var activeProxyDescription = "未选择"
    @Published var alert: String?
    @Published var acknowledgedMailboxTerms = false
    @Published var completedInRun = 0
    @Published var totalInRun = 0
    @Published var storageAvailable = true
    @Published var headerVariantStrategy = HeaderVariantStrategy(rawValue: UserDefaults.standard.string(forKey: "headerVariantStrategy") ?? "") ?? .fixed {
        didSet { UserDefaults.standard.set(headerVariantStrategy.rawValue, forKey: "headerVariantStrategy") }
    }
    @Published var headerConfiguration = RequestHeaderConfiguration.restore() {
        didSet { headerConfiguration.save() }
    }
    var useCompatibilityHeaders: Bool {
        get { headerConfiguration.mode == .safari }
        set { headerConfiguration.mode = newValue ? .safari : .webKit }
    }

    let networkMonitor = RequestMonitor()
    let store: JournalStore
    private let transportFactory: TransportFactory?
    private let proxyTest: ProxyTest
    private let retryDelaySeconds: TimeInterval
    private var nextProxyID: UUID?
    private var runRecordIDs: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var proxyTestTask: Task<Void, Never>?
    private var activeSessions: [URLSession] = []
    private var activeID: UUID?
    private var attemptID: UUID?
    private var submissionAttempted = false
    private var submitRequested = false
    private var codeRequired = true
    private var persistenceError: String?

    var journal: Journal {
        var value = Journal(); value.configuration = configuration; value.records = records
        value.proxyConfiguration = proxyConfiguration; return value
    }
    var successCount: Int { records.filter { $0.status == .succeeded }.count }
    var uncertainCount: Int { records.filter { $0.status == .uncertain }.count }
    var proxyLatencyError: String? {
        do { try proxyConfiguration.validateLatencyLimits(); return nil }
        catch { return error.localizedDescription }
    }
    var canSubmitNativeRegistration: Bool {
        isRunning && isManualFlow && waitingForCode && !isPaused && storageAvailable
            && (!codeRequired || validCode(manualCode))
    }

    init(store: JournalStore? = nil, passwordStore: PasswordStore = LocalPasswordStore(),
         transportFactory: TransportFactory? = nil,
         proxyTest: @escaping ProxyTest = { entry, config in
             await ProxyManager.test(entry, purpose: .beforeUse, configuration: config)
         }, retryDelaySeconds: TimeInterval = 5) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.store = store ?? JournalStore(directory: base.appendingPathComponent("BeautyRegistration", isDirectory: true))
        self.rememberedPassword = RememberedPassword(store: passwordStore)
        self.transportFactory = transportFactory
        self.proxyTest = proxyTest
        self.retryDelaySeconds = retryDelaySeconds.isFinite ? max(0.01, min(3_600, retryDelaySeconds)) : 5
        passwordObserver = rememberedPassword.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        monitorObserver = networkMonitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        do {
            var value = try self.store.load(); value.recoverInterruptedRun()
            configuration = value.configuration; records = value.records
            proxyConfiguration = value.proxyConfiguration
            try self.store.save(value)
        } catch {
            storageAvailable = false
            alert = "无法读取或写入本地记录。原文件已保留，修复后重启应用：\(self.store.fileURL.path)"
        }
        refreshNativeForm()
    }

    func refreshNativeForm() {
        guard !isRunning else { return }
        formUsername = configuration.username(configuration.startIndex)
        formEmail = configuration.email(configuration.startIndex)
    }

    private func validateRun() throws {
        try proxyConfiguration.validatePageLoadingTimeout()
        if proxyConfiguration.enabled {
            guard ProxyManager.isSupported else { throw ClientError.message("代理功能需要 macOS 14 或更高版本。") }
            try proxyConfiguration.validateLatencyLimits()
        }
    }

    private func makeClient(origin: String, headers: RequestHeaderConfiguration?, proxy: ProxyEntry?,
                            recordID: UUID?, token: UUID) throws -> NativeHTTPClient {
        let seconds = TimeInterval(proxyConfiguration.pageLoadingTimeoutSeconds)
        let transport: NativeHTTPClient.Transport
        if let transportFactory { transport = try transportFactory(proxy, seconds) }
        else {
            guard let session = ProxyManager.session(through: proxy, timeout: seconds) else {
                throw NativeAPIError.invalidConfiguration
            }
            activeSessions.append(session)
            transport = NativeHTTPClient.urlSessionTransport(session)
        }
        var fields = headers?.overrides ?? [:]
        if let userAgent = headers?.effectiveUserAgent,
           !fields.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            fields["User-Agent"] = userAgent
        }
        if let headers { networkMonitor.configure(headers) }
        return try NativeHTTPClient(baseURL: URL(string: origin)!, timeoutSeconds: seconds, headers: fields,
                                    transport: transport, onRecord: { [weak self] entry in
            guard let self, self.attemptID == token else { return }
            self.networkMonitor.record(entry)
            guard let recordID, self.activeID == recordID,
                  let index = self.records.firstIndex(where: { $0.id == recordID }) else { return }
            self.records[index].network.append(entry)
            if self.records[index].network.count > 100 { self.records[index].network.removeFirst(self.records[index].network.count - 100) }
            _ = self.persist()
        })
    }

    private func closeSessions() {
        activeSessions.forEach { $0.invalidateAndCancel() }
        activeSessions.removeAll()
        attemptID = nil
    }

    func checkAPIConnection() {
        guard !isRunning, !isCheckingConnection, !isTestingProxies else { return }
        do { try validateRun() } catch { alert = safeError(error); return }
        if proxyConfiguration.enabled && proxyConfiguration.activeEntries.isEmpty {
            alert = "请先添加可用代理。"; return
        }
        isCheckingConnection = true
        let headers = headerConfiguration
        let proxy = proxyConfiguration.proxy(forCompletedCount: completedInRun)
        activeProxyDescription = proxy?.displayName ?? "直接连接"
        connectionTask = Task {
            let token = UUID(); attemptID = token
            defer { closeSessions(); isCheckingConnection = false; connectionTask = nil }
            do {
                let api = RegistrationAPI(client: try makeClient(origin: "https://api.jiucaihezi.studio", headers: headers,
                                                                 proxy: proxy, recordID: nil, token: token))
                let status = try await api.status()
                try status.validateNativeRegistration()
                siteStatusDescription = "连接正常 · 注册可用"
            } catch {
                siteStatusDescription = safeError(error)
                alert = safeError(error)
            }
        }
    }

    func testProxies(_ entries: [ProxyEntry]) {
        guard storageAvailable, !isRunning, !isCheckingConnection, !isTestingProxies, !entries.isEmpty else { return }
        guard ProxyManager.isSupported else { alert = "代理功能需要 macOS 14 或更高版本。"; return }
        if let proxyLatencyError { alert = proxyLatencyError; return }
        let concurrency = min(ProxyManager.maximumBatchConcurrency, max(1, proxyTestConcurrency))
        let testConfiguration = proxyConfiguration
        proxyTestsCompleted = 0; proxyTestsTotal = entries.count; proxyTestsDiscarded = 0
        proxyTestPending = Set(entries.map(\.id))
        var results = proxyTestResults
        for entry in entries { results.removeValue(forKey: entry.id) }
        proxyTestResults = results
        isTestingProxies = true
        proxyTestTask = Task {
            var pending: [UUID: ProxyManager.TestResult] = [:]
            var lastFlush = ProcessInfo.processInfo.systemUptime
            // Batch UI updates and array removals; never rewrite a 10,000-entry journal per result.
            @MainActor func flush() {
                guard !pending.isEmpty else { return }
                let rejected = Set(pending.compactMap { ProxyManager.TestPurpose.pool.accepts($0.value, configuration: testConfiguration) ? nil : $0.key })
                if !rejected.isEmpty { proxyConfiguration.entries.removeAll { rejected.contains($0.id) } }
                proxyTestResults.merge(pending.filter { !rejected.contains($0.key) }) { _, new in new }
                proxyTestPending.subtract(pending.keys)
                proxyTestsCompleted += pending.count
                proxyTestsDiscarded += rejected.count
                pending.removeAll(keepingCapacity: true)
                lastFlush = ProcessInfo.processInfo.systemUptime
            }
            await ProxyManager.testBatch(entries, concurrencyLimit: concurrency, test: { entry in
                await ProxyManager.test(entry, configuration: testConfiguration)
            }, completed: { entry, result in
                pending[entry.id] = result
                if ProcessInfo.processInfo.systemUptime - lastFlush >= 0.2 { flush() }
            })
            flush()
            proxyTestPending.removeAll()
            isTestingProxies = false
            proxyTestTask = nil
            log("代理测试\(Task.isCancelled ? "已停止" : "完成")：已测 \(proxyTestsCompleted)/\(proxyTestsTotal)，丢弃 \(proxyTestsDiscarded) 个超时、超过 \(testConfiguration.poolTestLimitMilliseconds) ms 或不可用的代理。")
            _ = persist()
        }
    }

    func stopProxyTests() { proxyTestTask?.cancel() }

    func saveProxyLatencyLimits() {
        guard storageAvailable, proxyLatencyError == nil else { return }
        _ = persist()
    }

    private func discardProxyBeforeUse(_ entry: ProxyEntry, result: ProxyManager.TestResult, recordID: UUID) {
        guard ProxyManager.discardIfNeeded(entry, result: result, purpose: .beforeUse,
                                          configuration: &proxyConfiguration) else { return }
        let message = "已丢弃代理 \(entry.displayName)：\(result.summary)。自动尝试下一个代理。"
        log(message)
        appendLog(recordID, message, persistImmediately: false)
    }

    func start() {
        guard !isRunning, !isCheckingConnection, storageAvailable else { return }
        do { try configuration.validate(password: password); try validateRun() }
        catch { alert = safeError(error); return }
        guard !autoReadMailbox || acknowledgedMailboxTerms else {
            alert = "请先阅读邮箱服务条款，并勾选已阅读选项。"; return
        }
        let config = configuration
        let runPassword = password
        let batch = RegistrationBatch(configuration: config, records: records)
        guard batch.count > 0 else { alert = "这些用户名已有成功或待核对记录，请调整起始编号。"; return }
        guard persist() else { return }
        beginRun(manual: false, count: batch.count)
        let generator = HeaderVariantGenerator(strategy: headerVariantStrategy, base: headerConfiguration)
        if !batch.blockedIndices.isEmpty { log("跳过 \(batch.blockedIndices.count) 个已成功或待核对账号。") }
        log("开始原生接口注册，共 \(batch.count) 个账号。")
        let proxyTestsToDrain = proxyTestTask
        proxyTestsToDrain?.cancel()
        task = Task {
            await proxyTestsToDrain?.value
            var stopped = false
            for index in batch.indices where !batch.blockedIndices.contains(index) {
                if Task.isCancelled { stopped = true; break }
                let record = AccountRecord(username: config.username(index), email: config.email(index))
                records.append(record)
                prepareRecord(record)
                formUsername = record.username; formEmail = record.email
                var counted = false
                do {
                    try await runAccount(record, password: runPassword, invitation: config.invitation,
                                         headers: generator.variant(forIndex: index))
                    completedInRun += 1; counted = true
                    // Unknown submissions are retained for checking; continue other accounts immediately.
                    if completedInRun < totalInRun, records.first(where: { $0.id == record.id })?.status == .succeeded {
                        step = 5; phase = "等待下一个账号"
                        for remaining in (1...config.intervalSeconds).reversed() {
                            detail = "\(remaining) 秒后继续，\(completedInRun)/\(totalInRun) 已处理。"
                            try await tick()
                        }
                    }
                } catch {
                    let processed = finishFailure(record.id, error: error)
                    if processed && !counted { completedInRun += 1 }
                    configuration.startIndex = index
                    _ = persist()
                    stopped = true; break
                }
            }
            if !stopped {
                configuration.startIndex = batch.indices.upperBound
                _ = persist()
                do { try await gate() } catch { stopped = true }
            }
            finishRun(stopped: stopped)
            task = nil
        }
    }

    func requestNativeVerification() {
        guard !isRunning, !isCheckingConnection, storageAvailable else { return }
        let input = NativeRegistrationInput(username: formUsername, email: formEmail, password: password,
                                            invitation: configuration.invitation)
        do { try input.validate(requireCode: false); try validateRun() }
        catch { alert = safeError(error); return }
        if autoReadMailbox && isTemporaryMailbox(input.email) && !acknowledgedMailboxTerms {
            alert = "请先阅读邮箱服务条款，并勾选已阅读选项。"; return
        }
        guard !journal.blocksAutomaticRegistration(username: input.username) else {
            alert = "这个用户名已有成功或待核对记录，请先核对后再注册。"; return
        }
        guard persist() else { return }
        beginRun(manual: true, count: 1)
        let record = AccountRecord(username: input.username, email: input.email)
        records.append(record); prepareRecord(record)
        let headers = headerConfiguration
        let proxyTestsToDrain = proxyTestTask
        proxyTestsToDrain?.cancel()
        task = Task {
            await proxyTestsToDrain?.value
            var stopped = false
            do {
                try await runAccount(record, password: input.password, invitation: input.invitation,
                                     headers: headers)
                completedInRun = 1
            } catch {
                if finishFailure(record.id, error: error) { completedInRun = 1 }
                stopped = true
            }
            finishRun(stopped: stopped)
            task = nil
        }
    }

    func submitNativeRegistration() {
        guard canSubmitNativeRegistration else { return }
        submitRequested = true
    }

    private func beginRun(manual: Bool, count: Int) {
        persistenceError = nil
        isRunning = true; isPaused = false; isManualFlow = manual
        completedInRun = 0; totalInRun = count
        waitingForCode = false; verificationSent = false; submitRequested = false
        manualCode = ""; alert = nil
        nextProxyID = nil; runRecordIDs.removeAll()
    }

    private func prepareRecord(_ record: AccountRecord) {
        activeID = record.id; submissionAttempted = false
        runRecordIDs.insert(record.id)
        currentUsername = record.username; manualCode = ""
    }

    private func finishRun(stopped: Bool) {
        closeSessions(); activeID = nil
        isRunning = false; isPaused = false; waitingForCode = false; submitRequested = false
        phase = stopped ? "任务已停止" : "任务完成"
        let currentRecords = records.filter { runRecordIDs.contains($0.id) }
        let succeeded = currentRecords.filter { $0.status == .succeeded }.count
        let uncertain = currentRecords.filter { $0.status == .uncertain }.count
        detail = "本次已处理 \(completedInRun)/\(totalInRun) 个账号，成功 \(succeeded) 个、待核对 \(uncertain) 个。"
        if !stopped { step = 5 }
    }

    @discardableResult
    private func finishFailure(_ id: UUID, error: Error) -> Bool {
        let succeeded = records.first(where: { $0.id == id })?.status == .succeeded
        if !succeeded {
            let cancelled = error is CancellationError
            update(id, status: submissionAttempted ? .uncertain : (cancelled ? .cancelled : .failed),
                   note: submissionAttempted ? "提交后未取得明确结果，请在官网核对后处理。" : (cancelled ? "用户已停止任务。" : safeError(error)))
        }
        if !(error is CancellationError) { log("请求未完成：\(safeError(error))") }
        let status = records.first(where: { $0.id == id })?.status
        return status == .succeeded || status == .uncertain
    }

    private func runAccount(_ record: AccountRecord, password: String, invitation: String,
                            headers: RequestHeaderConfiguration) async throws {
        var excluded: Set<UUID> = []
        var previous: UUID?
        while true {
            try await gate()
            let proxy: ProxyEntry?
            do {
                defer { _ = persist() }
                let selection = try await ProxyManager.selectProxy(configuration: proxyConfiguration,
                    completedCount: completedInRun, startingAfter: previous, startingAt: nextProxyID,
                    excluding: excluded, test: { entry in
                        try await self.gate()
                        self.phase = "使用前复测代理"
                        self.detail = "正在复测 \(entry.displayName)，需低于 \(self.proxyConfiguration.preflightTestLimitMilliseconds) ms。"
                        let result = await self.proxyTest(entry, self.proxyConfiguration)
                        try await self.gate()
                        return result
                    }, discard: { entry, result in
                        self.discardProxyBeforeUse(entry, result: result, recordID: record.id)
                    })
                proxy = selection?.entry
                nextProxyID = nil
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                excluded.removeAll()
                try await waitToRetry(record.id, error: error)
                continue
            }
            try await gate()
            submissionAttempted = false; manualCode = ""; submitRequested = false
            waitingForCode = false; verificationSent = false
            activeProxyDescription = proxy?.displayName ?? "直接连接"
            update(record.id, status: .running, note: "正在连接注册接口。")
            do {
                try await register(record, password: password, invitation: invitation, headers: headers, proxy: proxy)
                try await gate()
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let proxy {
                    let pool = proxyConfiguration.activeEntries
                    if let index = pool.firstIndex(where: { $0.id == proxy.id }), pool.count > 1 {
                        nextProxyID = pool[(index + 1) % pool.count].id
                    }
                    if (error as? NativeAPIError)?.isTimeout == true {
                        nextProxyID = ProxyManager.discardTimedOutProxy(proxy, configuration: &proxyConfiguration)
                        appendLog(record.id, "接口超时，已丢弃代理 \(proxy.displayName)。")
                    }
                    previous = proxy.id
                    excluded.insert(proxy.id)
                }
                if records.first(where: { $0.id == record.id })?.status == .succeeded {
                    try await gate()
                    return
                }
                if submissionAttempted {
                    update(record.id, status: .uncertain, note: "提交后未取得明确结果，请在官网核对；任务继续处理其他账号。")
                    let message = "\(record.username)：提交结果待核对，自动切换代理并继续其他账号。"
                    log(message); appendLog(record.id, message)
                    try await gate()
                    return
                }
                let message = "\(proxy.map { "代理 " + $0.displayName } ?? "直接连接") 请求失败：\(safeError(error)) 自动\(proxy == nil ? "重试" : "切换下一个代理")。"
                phase = proxy == nil ? "自动重试" : "切换代理"
                detail = "正在继续注册 \(record.username)。"
                log(message); appendLog(record.id, message)
                if proxy == nil { try await waitToRetry(record.id, error: error) }
            }
        }
    }

    private func waitToRetry(_ recordID: UUID, error: Error) async throws {
        let emptyPool = proxyConfiguration.enabled && proxyConfiguration.activeEntries.isEmpty
        phase = emptyPool ? "等待可用代理" : "自动重试"
        let seconds = proxyConfiguration.enabled ? retryDelaySeconds : max(retryDelaySeconds, Double(configuration.cooldownMinutes) * 60)
        detail = emptyPool ? "代理池为空，可在代理页补充代理，任务会自动继续。" : "本轮请求未完成，稍后自动继续重试当前账号。"
        let message = "\(safeError(error)) \(detail)"
        log(message); appendLog(recordID, message)
        try await tick(nanoseconds: UInt64(min(seconds, 3_600) * 1_000_000_000))
    }

    private func register(_ record: AccountRecord, password: String, invitation: String,
                          headers: RequestHeaderConfiguration, proxy: ProxyEntry?) async throws {
        let token = UUID(); attemptID = token
        var exitLookup: Task<Void, Never>?
        defer { exitLookup?.cancel(); closeSessions(); waitingForCode = false }
        step = 1; phase = "连接注册接口"; detail = "正在检查注册服务。"; tab = "registration"
        let api = RegistrationAPI(client: try makeClient(origin: "https://api.jiucaihezi.studio", headers: headers,
                                                         proxy: proxy, recordID: record.id, token: token))
        let status = try await api.status()
        try status.validateNativeRegistration()
        siteStatusDescription = "连接正常 · 注册可用"
        codeRequired = status.emailVerificationEnabled
        try await gate()
        if let proxy, transportFactory == nil {
            exitLookup = Task { [weak self] in
                let info = await ProxyManager.exitInfo(through: proxy)
                guard !Task.isCancelled, let self, self.attemptID == token, self.activeID == record.id else { return }
                if let info {
                    self.log("出口 IP：\(info.summary)")
                    self.appendLog(record.id, "出口 IP：\(info.summary)")
                }
            }
        }
        appendLog(record.id, "已连接注册接口，\(codeRequired ? "需要邮箱验证码" : "无需邮箱验证码")。")
        var mailbox: MailboxAPI?
        var baseline = Set<String>()
        let parts = record.email.split(separator: "@", maxSplits: 1).map(String.init)
        if codeRequired && autoReadMailbox && isTemporaryMailbox(record.email) {
            step = 2; phase = "准备临时邮箱"; detail = "正在连接邮箱接口。"
            let value = MailboxAPI(client: try makeClient(origin: "https://fviainboxes.com", headers: nil,
                                                         proxy: proxy, recordID: record.id, token: token))
            try await value.checkAvailability()
            try await gate()
            baseline = Set(try await value.messages(username: parts[0], domain: parts[1]).map(\.id))
            mailbox = value
        }
        var requestedAt = Date().timeIntervalSince1970
        if codeRequired {
            step = 3; phase = "请求验证码"; detail = "正在请求验证邮件。"
            try await VerificationRetry.send(retryRateLimits: !proxyConfiguration.enabled, attempt: {
                try await self.gate()
                requestedAt = Date().timeIntervalSince1970
                let reply = try await api.sendVerification(email: record.email)
                if reply.requiresInteraction { throw NativeAPIError.interactionRequired("注册站点") }
                self.appendLog(record.id, "请求验证码 → HTTP \(reply.statusCode)\(reply.message.isEmpty ? "" : "：" + reply.message)")
                return reply.retryDictionary
            }, wait: { seconds, retry in
                self.phase = "等待发送冷却"
                for remaining in (1...seconds).reversed() {
                    self.detail = "发送过于频繁，\(remaining) 秒后重试（\(retry)/\(VerificationRetry.maximumRetries)）。"
                    try await self.tick()
                }
            })
            verificationSent = true
        }
        try await gate()
        waitingForCode = true
        phase = codeRequired ? "等待邮件验证码" : "等待提交注册"
        detail = codeRequired ? (mailbox == nil ? "请手动填写验证码。" : "正在读取新邮件，也可以手动填写验证码。") : "网站无需验证码，点击注册用户继续。"
        var seen = baseline
        var nextPoll = ProcessInfo.processInfo.systemUptime
        while true {
            try await gate()
            let ready = !codeRequired || validCode(manualCode)
            if ready && (!isManualFlow || submitRequested) { break }
            if !ready, let currentMailbox = mailbox, ProcessInfo.processInfo.systemUptime >= nextPoll {
                let messages = try await currentMailbox.messages(username: parts[0], domain: parts[1])
                let candidates = MailVerification.candidates(in: messages, excluding: seen, requestedAt: requestedAt)
                for message in candidates {
                    try await gate()
                    let html = try await currentMailbox.messageHTML(username: parts[0], domain: parts[1], id: message.id)
                    guard let code = MailVerification.code(fromHTML: html) else {
                        throw ClientError.message("验证邮件没有可识别的验证码，将切换代理重试。")
                    }
                    seen.insert(message.id)
                    // A code entered while a mailbox request was in flight takes priority.
                    if !validCode(manualCode) {
                        manualCode = code
                        appendLog(record.id, "已自动读取并填入验证码。")
                        log("\(record.username)：已自动读取并填入验证码。")
                    }
                    detail = isManualFlow ? "验证码已填入，点击注册用户完成注册。" : "验证码已填入，准备提交注册。"
                    break
                }
                nextPoll = ProcessInfo.processInfo.systemUptime + 2
            }
            try await tick(nanoseconds: 100_000_000)
        }
        let input = NativeRegistrationInput(username: record.username, email: record.email, password: password,
                                            verificationCode: codeRequired ? manualCode : "", invitation: invitation)
        try input.validate(requireCode: codeRequired, requireEmail: codeRequired)
        try await gate()
        waitingForCode = false; submitRequested = false
        step = 4; phase = "提交注册"; detail = "正在等待服务器返回注册结果。"
        // Save before POST so interrupted or unknown submissions can never be repeated automatically.
        submissionAttempted = true
        update(record.id, status: .submitting, note: "准备提交，等待网站回执。")
        if let persistenceError {
            submissionAttempted = false
            update(record.id, status: .running, note: "本地记录暂不可写，尚未发送注册请求，恢复后自动重试。")
            throw ClientError.message(persistenceError)
        }
        let reply = try await api.register(input, requireCode: codeRequired)
        // Process explicit server results before checking cancellation or pause.
        if reply.success {
            update(record.id, status: .succeeded, note: "注册接口已明确返回成功。")
            appendLog(record.id, "提交结果 → HTTP \(reply.statusCode) 注册成功。")
            log("\(record.username)：注册成功。")
            step = 5; phase = "保存结果"
            return
        }
        submissionAttempted = !reply.explicitlyRejected
        if !submissionAttempted { update(record.id, status: .running, note: "网站已明确拒绝本次注册，可切换代理重试。") }
        throw reply.failure(operation: "注册")
    }

    private func isTemporaryMailbox(_ email: String) -> Bool {
        email.split(separator: "@", maxSplits: 1).last?.lowercased() == "fviainboxes.com"
    }
    private func validCode(_ code: String) -> Bool {
        code.range(of: #"^[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil
    }
    private func gate() async throws {
        try Task.checkCancellation()
        while isPaused { try await Task.sleep(nanoseconds: 100_000_000); try Task.checkCancellation() }
        while persistenceError != nil {
            try Task.checkCancellation()
            while isPaused { try await Task.sleep(nanoseconds: 100_000_000); try Task.checkCancellation() }
            phase = "等待本地记录恢复"
            detail = "本地记录暂不可写，正在自动重试保存；恢复后继续任务。"
            if persist() { break }
            try await Task.sleep(nanoseconds: UInt64(retryDelaySeconds * 1_000_000_000))
        }
    }
    private func tick(nanoseconds: UInt64 = 1_000_000_000) async throws {
        try await gate(); try await Task.sleep(nanoseconds: nanoseconds); try Task.checkCancellation()
    }
    func togglePause() { guard isRunning else { return }; isPaused.toggle() }
    func stop() {
        task?.cancel(); connectionTask?.cancel()
        activeSessions.forEach { $0.invalidateAndCancel() }
        isPaused = false
        detail = "正在停止。已提交的请求仍可能在服务器完成。"
    }
    private func safeError(_ error: Error) -> String {
        if let error = error as? NativeAPIError { return error.localizedDescription }
        if let error = error as? ClientError { return error.localizedDescription }
        if let error = error as? ProxyManager.SelectionError { return error.localizedDescription }
        return "接口请求未完成，请检查网络后重试。"
    }
    private func update(_ id: UUID, status: RecordStatus, note: String) {
        guard let i = records.firstIndex(where: {$0.id == id}) else { return }
        records[i].status = status; records[i].note = note; records[i].updatedAt = Date(); _ = persist()
    }
    private func appendLog(_ id: UUID, _ text: String, persistImmediately: Bool = true) {
        guard let i = records.firstIndex(where: {$0.id == id}) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        records[i].logs.append("\(formatter.string(from: Date()))  \(text)")
        if records[i].logs.count > 500 { records[i].logs.removeFirst(records[i].logs.count - 500) }
        if persistImmediately { _ = persist() }
    }
    @discardableResult private func persist() -> Bool {
        guard storageAvailable else { return false }
        do { try store.save(journal); persistenceError = nil; return true }
        catch {
            persistenceError = "本地记录暂不可写，恢复后自动继续。"
            if !isRunning { alert = persistenceError }
            return false
        }
    }
    private func log(_ text: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        logs.append("\(formatter.string(from: Date()))  \(text)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
    func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "注册记录.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Journal.csv(records).write(to: url, atomically: true, encoding: .utf8) }
        catch { alert = "导出失败，请选择可写入的目录。" }
    }
    func revealRecords() { NSWorkspace.shared.open(store.directory) }
    func resolveRecord(_ id: UUID, exists: Bool) {
        guard !isRunning, records.first(where: {$0.id == id})?.status == .uncertain else { return }
        update(id, status: exists ? .succeeded : .failed,
               note: exists ? "用户已在官网核对：账号注册成功。" : "用户已在官网核对：账号未注册，允许重新创建任务。")
    }
}
