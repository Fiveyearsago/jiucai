import AppKit
import Combine
import RegistrationCore

enum RegistrationMethod {
    case native, webpage
}

@MainActor
final class RegistrationModel: ObservableObject {
    typealias TransportFactory = (ProxyEntry?, TimeInterval) throws -> NativeHTTPClient.Transport
    typealias ProxyTest = (ProxyEntry, ProxyConfiguration) async -> ProxyManager.TestResult
    typealias ProxySourceFetch = (URL) async throws -> String

    @Published var configuration = TaskConfiguration()
    @Published var proxyConfiguration = ProxyConfiguration()
    @Published var proxyTestConcurrency = ProxyManager.defaultBatchConcurrency
    @Published private(set) var isTestingProxies = false
    @Published private(set) var proxyTestResults: [UUID: ProxyManager.TestResult] = [:]
    @Published private(set) var proxyTestPending: Set<UUID> = []
    @Published private(set) var proxyTestsCompleted = 0
    @Published private(set) var proxyTestsTotal = 0
    @Published private(set) var proxyTestsDiscarded = 0
    @Published private(set) var isRefreshingProxySources = false
    @Published private(set) var proxySourceStatus = "尚未更新代理来源"
    @Published private(set) var proxySourceCandidates = 0
    @Published private(set) var proxySourceTested = 0
    @Published private(set) var proxySourceAdded = 0
    @Published private(set) var proxySourceRejected = 0
    @Published private(set) var proxySourceErrors: [String] = []
    @Published private(set) var lastProxySourceRefreshAt: Date?
    @Published private(set) var nextProxySourceRefreshAt: Date?
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
    @Published var registrationMethod: RegistrationMethod = .native
    @Published private(set) var activeRegistrationMethod: RegistrationMethod = .native
    @Published private(set) var pagesOpened = false
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
    private(set) lazy var registrationPage: BrowserPane = {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        pane.onNetworkRecord = { [weak self] entry in
            guard let self else { return }
            self.networkMonitor.record(entry)
            guard self.isRunning, self.activeRegistrationMethod == .webpage,
                  let id = self.activeID, let index = self.records.firstIndex(where: { $0.id == id }) else { return }
            self.records[index].network.append(entry)
            if self.records[index].network.count > 100 { self.records[index].network.removeFirst() }
            _ = self.persist()
        }
        pane.onRegistration = { [weak self] response in
            guard let self, self.isRunning, self.activeRegistrationMethod == .webpage,
                  self.submissionAttempted, let id = self.activeID,
                  response["success"] as? Bool == true,
                  let status = response["status"] as? Int, (200..<300).contains(status) else { return }
            self.update(id, status: .succeeded, note: "网站注册接口已明确返回成功。")
        }
        return pane
    }()
    private(set) lazy var mailboxPage = BrowserPane(host: "fviainboxes.com")
    // Tests can supply local WebKit pages without contacting either service.
    var browserPageLoader: ((BrowserPane, URL, RequestHeaderConfiguration) -> Void)?
    let store: JournalStore
    private let transportFactory: TransportFactory?
    private let poolProxyTest: ProxyTest
    private let proxySourceFetch: ProxySourceFetch
    private let proxyNetworkScheduler = ProxyNetworkScheduler()
    private var proxySourceTask: Task<Void, Never>?
    private var proxySourceTimer: Task<Void, Never>?
    private var rejectedDuringSourceRefresh: Set<ProxyIdentity> = []
    private let retryDelaySeconds: TimeInterval
    private var proxyRotation = ProxyRotationQueue()
    private var currentProxy: ProxyEntry?
    private var accountsWithCurrentProxy = 0
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
         retryDelaySeconds: TimeInterval = 5,
         proxySourceFetch: @escaping ProxySourceFetch = { try await ProxySourceClient.fetch(from: $0) },
         poolProxyTest: @escaping ProxyTest = { entry, config in await ProxyManager.test(entry, configuration: config) }) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.store = store ?? JournalStore(directory: base.appendingPathComponent("BeautyRegistration", isDirectory: true))
        self.rememberedPassword = RememberedPassword(store: passwordStore)
        self.transportFactory = transportFactory
        self.poolProxyTest = poolProxyTest
        self.proxySourceFetch = proxySourceFetch
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
                                    transport: { [weak self] request in
            guard let self else { throw CancellationError() }
            try await self.gate()
            return try await self.proxyNetworkScheduler.foreground(whenReady: { !self.isPaused }) {
                try await self.gate()
                return try await transport(request)
            }
        }, onRecord: { [weak self] entry in
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
        guard storageAvailable, !isRunning, !isCheckingConnection, !isTestingProxies, !isRefreshingProxySources, !entries.isEmpty else { return }
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
                let rejected = Set(pending.compactMap { ProxyManager.acceptsPoolResult($0.value, configuration: testConfiguration) ? nil : $0.key })
                if !rejected.isEmpty { proxyConfiguration.entries.removeAll { rejected.contains($0.id) } }
                proxyTestResults.merge(pending.filter { !rejected.contains($0.key) }) { _, new in new }
                proxyTestPending.subtract(pending.keys)
                proxyTestsCompleted += pending.count
                proxyTestsDiscarded += rejected.count
                pending.removeAll(keepingCapacity: true)
                lastFlush = ProcessInfo.processInfo.systemUptime
            }
            await ProxyManager.testBatch(entries, concurrencyLimit: concurrency, test: { entry in
                await self.testPoolProxy(entry, configuration: testConfiguration)
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

    func start(method: RegistrationMethod = .native) {
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
        beginRun(manual: false, count: batch.count, method: method)
        let generator = HeaderVariantGenerator(strategy: headerVariantStrategy, base: headerConfiguration)
        if !batch.blockedIndices.isEmpty { log("跳过 \(batch.blockedIndices.count) 个已成功或待核对账号。") }
        log("开始\(method == .webpage ? "网页" : "原生接口")注册，共 \(batch.count) 个账号。")
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

    private func beginRun(manual: Bool, count: Int, method: RegistrationMethod = .native) {
        persistenceError = nil
        isRunning = true; isPaused = false; isManualFlow = manual
        activeRegistrationMethod = method; registrationMethod = method
        if pagesOpened { registrationPage.stopLoading(); mailboxPage.stopLoading() }
        proxyNetworkScheduler.setRegistrationConcurrency(proxyConfiguration.sourceConfiguration.registrationConcurrency)
        completedInRun = 0; totalInRun = count
        waitingForCode = false; verificationSent = false; submitRequested = false
        manualCode = ""; alert = nil
        proxyRotation = ProxyRotationQueue(); currentProxy = nil; accountsWithCurrentProxy = 0
        runRecordIDs.removeAll()
    }

    private func prepareRecord(_ record: AccountRecord) {
        activeID = record.id; submissionAttempted = false
        runRecordIDs.insert(record.id)
        currentUsername = record.username; manualCode = ""
    }

    private func finishRun(stopped: Bool) {
        closeSessions(); activeID = nil
        proxyRotation = ProxyRotationQueue()
        currentProxy = nil; accountsWithCurrentProxy = 0
        isRunning = false; isPaused = false; waitingForCode = false; submitRequested = false
        proxyNetworkScheduler.setRegistrationConcurrency(nil)
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
        while true {
            try await gate()
            let proxy: ProxyEntry?
            if let currentProxy, proxyConfiguration.enabled, proxyConfiguration.entries.contains(currentProxy) {
                // Reuse the selected proxy for its whole account group until a request fails.
                proxy = currentProxy
            } else {
                currentProxy = nil; accountsWithCurrentProxy = 0
                do {
                    let selectionConfiguration = proxyRotation.selectionConfiguration(from: proxyConfiguration)
                    proxy = try ProxyManager.selectProxy(configuration: selectionConfiguration, completedCount: 0)
                    currentProxy = proxy
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    try await waitToRetry(record.id, error: error)
                    continue
                }
            }
            try await gate()
            submissionAttempted = false; manualCode = ""; submitRequested = false
            waitingForCode = false; verificationSent = false
            activeProxyDescription = proxy?.displayName ?? "直接连接"
            update(record.id, status: .running, note: "正在连接注册接口。")
            do {
                if activeRegistrationMethod == .webpage {
                    try await registerInBrowser(record, password: password, invitation: invitation, headers: headers, proxy: proxy)
                } else {
                    try await register(record, password: password, invitation: invitation, headers: headers, proxy: proxy)
                }
                try await gate()
                if let proxy {
                    accountsWithCurrentProxy += 1
                    if accountsWithCurrentProxy >= max(1, proxyConfiguration.switchEvery) {
                        proxyRotation.didFinishProxy(id: proxy.id)
                        currentProxy = nil; accountsWithCurrentProxy = 0
                    }
                }
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let proxy {
                    _ = ProxyManager.discardFailedProxy(proxy, configuration: &proxyConfiguration)
                    proxyRotation.didFinishProxy(id: proxy.id)
                    if isRefreshingProxySources { rejectedDuringSourceRefresh.insert(ProxyIdentity(proxy)) }
                    currentProxy = nil; accountsWithCurrentProxy = 0
                    appendLog(record.id, "注册流程失败，已丢弃代理 \(proxy.displayName)。")
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
                guard let self else { return }
                let info = try? await self.proxyNetworkScheduler.background { await ProxyManager.exitInfo(through: proxy) }
                guard !Task.isCancelled, self.attemptID == token, self.activeID == record.id else { return }
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
        if pagesOpened { registrationPage.stopLoading(); mailboxPage.stopLoading() }
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
    @discardableResult private func persist(reportError: Bool = true) -> Bool {
        guard storageAvailable else { return false }
        do { try store.save(journal); persistenceError = nil; return true }
        catch {
            persistenceError = "本地记录暂不可写，恢复后自动继续。"
            if reportError && !isRunning { alert = persistenceError }
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

extension RegistrationModel {
    func openPages() {
        guard !isRunning, !isCheckingConnection else { return }
        do {
            try validateRun()
            let proxy = try ProxyManager.selectProxy(configuration: proxyConfiguration, completedCount: completedInRun)
            prepareBrowserPages(proxy: proxy, headers: headerConfiguration)
            loadBrowserPage(registrationPage, url: configuration.registrationURL, headers: headerConfiguration)
            loadBrowserPage(mailboxPage, url: URL(string: "https://fviainboxes.com")!, headers: .webKit)
        } catch { alert = safeError(error) }
    }

    private func prepareBrowserPages(proxy: ProxyEntry?, headers: RequestHeaderConfiguration) {
        registrationPage.rebuildWebView(proxy: proxy)
        mailboxPage.rebuildWebView(proxy: proxy)
        registrationPage.loadingTimeout = TimeInterval(proxyConfiguration.pageLoadingTimeoutSeconds)
        mailboxPage.loadingTimeout = TimeInterval(proxyConfiguration.pageLoadingTimeoutSeconds)
        activeProxyDescription = proxy?.displayName ?? "直接连接"
        networkMonitor.configure(headers)
        pagesOpened = true
    }

    private func loadBrowserPage(_ pane: BrowserPane, url: URL, headers: RequestHeaderConfiguration) {
        if let browserPageLoader { browserPageLoader(pane, url, headers) }
        else { pane.load(url, headers: headers) }
    }

    private func registerInBrowser(_ record: AccountRecord, password: String, invitation: String,
                                   headers: RequestHeaderConfiguration, proxy: ProxyEntry?) async throws {
        defer { waitingForCode = false }
        prepareBrowserPages(proxy: proxy, headers: headers)
        var config = configuration; config.invitation = invitation
        step = 1; phase = "打开注册网页"; detail = "正在载入官网注册页面。"; tab = "registration"
        appendLog(record.id, "开始网页注册流程。")
        loadBrowserPage(registrationPage, url: config.registrationURL, headers: headers)
        try await waitForBrowser(pane: registrationPage, message: "注册页面尚未就绪，请检查网页。") {
            await self.registrationPage.snapshot()["regReady"] as? Bool == true
        }
        try await gate()
        let filled = try await registrationPage.call("fillRegistration", arguments: [
            "username": record.username, "email": record.email, "password": password
        ]) as? [String: Any]
        codeRequired = filled?["requiresEmail"] as? Bool == true
        if codeRequired && autoReadMailbox {
            step = 2; phase = "准备网页邮箱"; detail = "正在载入邮箱页面。"; tab = "mailbox"
            loadBrowserPage(mailboxPage, url: URL(string: "https://fviainboxes.com")!, headers: .webKit)
            try await waitForBrowser(pane: mailboxPage, message: "邮箱页面尚未就绪，请检查邮箱域名或网页验证。") {
                let state = await self.mailboxPage.snapshot()
                if let status = state["mailStatus"] as? String, !status.isEmpty { self.detail = status }
                return state["mailReady"] as? Bool == true
            }
            try await gate()
            guard try await mailboxPage.call("prepareMailbox", arguments: ["username": record.username]) as? String == "prepared" else {
                throw ClientError.message("邮箱尚未准备完成，请检查邮箱页。")
            }
            _ = try await mailboxPage.call("armMailbox")
        }
        if codeRequired {
            step = 3; phase = "发送网页验证码"; detail = "正在通过官网发送验证邮件。"; tab = "registration"
            try await VerificationRetry.send(retryRateLimits: !proxyConfiguration.enabled, attempt: {
                try await self.gate()
                self.registrationPage.verification = nil
                try await self.clickBrowserButton("sendCode", message: "请在注册页完成人机验证或检查邮箱字段，然后点击继续任务。")
                try await self.waitForBrowser(pane: self.registrationPage, message: "发送验证码的结果未确认，请检查官网提示。") {
                    self.registrationPage.verification != nil
                }
                let result = self.registrationPage.verification ?? [:]
                self.appendLog(record.id, "网页发送验证码 → HTTP \(result["status"] as? Int ?? 0)")
                return result
            }, wait: { seconds, retry in
                self.phase = "等待发送冷却"
                for remaining in (1...seconds).reversed() {
                    self.detail = "发送过于频繁，\(remaining) 秒后重试（\(retry)/\(VerificationRetry.maximumRetries)）。"
                    try await self.tick()
                }
            })
            verificationSent = true; waitingForCode = true
            phase = "等待邮件验证码"
            detail = autoReadMailbox ? "正在读取网页邮箱，也可以手动填写验证码。" : "请查看邮箱并在上方手动填写验证码。"
            if autoReadMailbox {
                tab = "mailbox"
                _ = try await mailboxPage.call("beginMailboxPolling")
            }
            while !validCode(manualCode) {
                try await gate()
                if autoReadMailbox {
                    if let error = mailboxPage.navigationError { throw ClientError.message(error) }
                    _ = try await mailboxPage.call("pollMailbox")
                    let state = await mailboxPage.snapshot()
                    if let problem = state["problem"] as? String, !problem.isEmpty {
                        try await browserAttention(problem + " 完成后点击继续任务。", tab: "mailbox")
                        _ = try await mailboxPage.call("beginMailboxPolling")
                    }
                    if !validCode(manualCode), let code = state["code"] as? String, validCode(code) { manualCode = code }
                }
                if !validCode(manualCode) { try await tick(nanoseconds: 200_000_000) }
            }
            try await gate()
            _ = try await registrationPage.call("fillCode", arguments: ["code": manualCode])
            appendLog(record.id, "已填入网页验证码。")
            manualCode = ""; waitingForCode = false
        }
        step = 4; phase = "提交网页注册"; detail = "等待网站返回明确结果。"; tab = "registration"
        while true {
            try await gate()
            // Persist before clicking submit; a timeout or crash must never repeat an unknown POST.
            submissionAttempted = true
            update(record.id, status: .submitting, note: "准备通过网页提交，等待网站回执。")
            if let persistenceError {
                submissionAttempted = false
                update(record.id, status: .running, note: "本地记录暂不可写，尚未提交网页注册。")
                throw ClientError.message(persistenceError)
            }
            if try await registrationPage.call("submit") as? String == "clicked" { break }
            submissionAttempted = false
            update(record.id, status: .running, note: "等待用户完成网页验证或条款确认。")
            try await browserAttention("请在注册页阅读并确认网站条款、完成人机验证，然后点击继续任务。", tab: "registration")
        }
        try await waitForBrowser(pane: registrationPage, message: "提交后未收到明确回执，请在官网核对账号。") {
            self.registrationPage.registration != nil
        }
        let result = registrationPage.registration ?? [:]
        if result["success"] as? Bool == true, let status = result["status"] as? Int, (200..<300).contains(status) {
            update(record.id, status: .succeeded, note: "网站注册接口已明确返回成功。")
            appendLog(record.id, "网页提交结果 → HTTP \(status) 注册成功。")
            log("\(record.username)：网页注册成功。")
            step = 5; phase = "保存结果"
        } else {
            submissionAttempted = result["rejected"] as? Bool != true
            throw ClientError.message(ServerFailure.describe(result, operation: "网页注册"))
        }
    }

    private func waitForBrowser(pane: BrowserPane, message: String,
                                condition: () async throws -> Bool) async throws {
        var remaining = TimeInterval(proxyConfiguration.pageLoadingTimeoutSeconds)
        while true {
            try await gate()
            if try await condition() { return }
            if let error = pane.navigationError { throw ClientError.message(error) }
            guard remaining > 0 else { throw ClientError.message(message) }
            let interval = min(remaining, 0.2)
            try await tick(nanoseconds: UInt64(interval * 1_000_000_000))
            remaining -= interval
        }
    }

    private func clickBrowserButton(_ method: String, message: String) async throws {
        while true {
            try await gate()
            if try await registrationPage.call(method) as? String == "clicked" { return }
            try await browserAttention(message, tab: "registration")
        }
    }

    private func browserAttention(_ message: String, tab: String) async throws {
        self.tab = tab; phase = "等待网页操作"; detail = message; isPaused = true
        log(message)
        try await gate()
    }
}

extension RegistrationModel {
    private func testPoolProxy(_ entry: ProxyEntry, configuration: ProxyConfiguration) async -> ProxyManager.TestResult {
        do {
            return try await proxyNetworkScheduler.background { await self.poolProxyTest(entry, configuration) }
        } catch {
            // The cancelled batch drops this result; foreground preemption is retried by the scheduler.
            return .init(verdict: .unreachable, status: nil, milliseconds: 0, exit: nil, error: "测速已取消")
        }
    }

    /// The window starts one app-lifetime timer; changing tabs or opening another window is harmless.
    func startProxySourceUpdates() {
        guard proxySourceTimer == nil, storageAvailable, ProxyManager.isSupported else { return }
        if proxyConfiguration.sourceConfiguration.automatic { nextProxySourceRefreshAt = Date() }
        proxySourceTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                self?.refreshProxySourcesIfDue()
                if self == nil { return }
            }
        }
        refreshProxySourcesIfDue()
    }

    func stopProxySourceUpdates() {
        proxySourceTimer?.cancel(); proxySourceTimer = nil
        stopProxySourceRefresh()
        nextProxySourceRefreshAt = nil
    }

    func refreshProxySourcesIfDue(at now: Date = Date()) {
        let settings = proxyConfiguration.sourceConfiguration
        guard storageAvailable, settings.automatic, !settings.urls.isEmpty else {
            nextProxySourceRefreshAt = nil
            return
        }
        guard let next = nextProxySourceRefreshAt, now >= next,
              !isRefreshingProxySources, !isTestingProxies else { return }
        refreshProxySources(now: now)
    }

    @discardableResult
    func saveRegistrationProxyConcurrency(_ limit: Int) -> Bool {
        var settings = proxyConfiguration.sourceConfiguration
        settings.registrationConcurrency = limit
        do { try settings.validate() } catch { proxySourceStatus = safeError(error); return false }
        proxyConfiguration.sourceConfiguration = settings
        if isRunning { proxyNetworkScheduler.setRegistrationConcurrency(limit) }
        return persist(reportError: false)
    }

    @discardableResult
    func saveProxySourceConfiguration(_ value: ProxySourceConfiguration) -> Bool {
        guard storageAvailable else { return false }
        do { try value.validate() } catch { proxySourceStatus = safeError(error); return false }
        var normalized = value
        var seen: Set<String> = []
        normalized.urls = value.urls.compactMap { raw in
            guard let url = try? ProxySources.url(from: raw), seen.insert(url.absoluteString).inserted else { return nil }
            return url.absoluteString
        }
        proxyConfiguration.sourceConfiguration = normalized
        if isRunning { proxyNetworkScheduler.setRegistrationConcurrency(normalized.registrationConcurrency) }
        guard persist(reportError: false) else {
            proxySourceStatus = "代理来源设置暂未保存，本地记录恢复后请再次保存。"
            return false
        }
        scheduleNextProxySourceRefresh(from: Date())
        proxySourceStatus = normalized.automatic ? "已保存，按设定间隔自动更新代理。" : "已关闭定时更新，仍可手动更新。"
        return true
    }

    private func scheduleNextProxySourceRefresh(from now: Date) {
        let settings = proxyConfiguration.sourceConfiguration
        nextProxySourceRefreshAt = settings.automatic && !settings.urls.isEmpty
            ? now.addingTimeInterval(Double(settings.intervalMinutes) * 60) : nil
    }

    func refreshProxySources(now: Date = Date()) {
        guard storageAvailable, !isRefreshingProxySources else { return }
        guard !isTestingProxies else {
            proxySourceStatus = "等待当前手动批量测试结束后再更新来源。"
            return
        }
        guard ProxyManager.isSupported else { proxySourceStatus = "代理功能需要 macOS 14 或更高版本。"; return }
        scheduleNextProxySourceRefresh(from: now)
        let settings = proxyConfiguration.sourceConfiguration
        do { try settings.validate(); try proxyConfiguration.validateLatencyLimits() }
        catch { proxySourceStatus = safeError(error); return }
        guard !settings.urls.isEmpty else { proxySourceStatus = "请先添加代理来源。"; return }
        var seenURLs: Set<String> = []
        let urls = settings.urls.compactMap { raw -> URL? in
            guard let url = try? ProxySources.url(from: raw), seenURLs.insert(url.absoluteString).inserted else { return nil }
            return url
        }
        let testConfiguration = proxyConfiguration
        let concurrency = min(ProxyManager.maximumBatchConcurrency, max(1, proxyTestConcurrency))
        isRefreshingProxySources = true
        proxySourceCandidates = 0; proxySourceTested = 0; proxySourceAdded = 0; proxySourceRejected = 0
        proxySourceErrors.removeAll(); rejectedDuringSourceRefresh.removeAll()
        proxySourceStatus = "正在下载代理来源。"
        proxySourceTask = Task {
            defer {
                lastProxySourceRefreshAt = Date()
                isRefreshingProxySources = false; proxySourceTask = nil
                rejectedDuringSourceRefresh.removeAll()
            }
            do {
                var lists: [String] = []
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    proxySourceStatus = "正在下载来源 \(index + 1)/\(urls.count)：\(url.host ?? "")"
                    do {
                        let text = try await proxyNetworkScheduler.background { try await self.proxySourceFetch(url) }
                        try Task.checkCancellation()
                        lists.append(text)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        let reason = (error as? ClientError)?.localizedDescription ?? "下载失败，下次更新时重试。"
                        proxySourceErrors.append("来源 \(index + 1)（\(url.host ?? "")）：\(reason)")
                    }
                }
                let existing = proxyConfiguration.entries
                let candidates = await Task.detached(priority: .utility) { [lists, existing] in
                    ProxySources.candidates(in: lists, excluding: existing)
                }.value
                try Task.checkCancellation()
                proxySourceCandidates = candidates.count
                proxySourceStatus = "正在测速新代理，仅把通过测试的代理加入池中。"
                var pending: [(ProxyEntry, ProxyManager.TestResult)] = []
                var lastFlush = ProcessInfo.processInfo.systemUptime - 1
                @MainActor func flush() {
                    guard !pending.isEmpty else { return }
                    var known = Set(proxyConfiguration.entries.map(ProxyIdentity.init))
                    var additions: [ProxyEntry] = []
                    var results: [UUID: ProxyManager.TestResult] = [:]
                    for (entry, result) in pending {
                        let identity = ProxyIdentity(entry)
                        if ProxyManager.acceptsPoolResult(result, configuration: testConfiguration),
                           !rejectedDuringSourceRefresh.contains(identity) {
                            if known.insert(identity).inserted { additions.append(entry); results[entry.id] = result }
                        } else { proxySourceRejected += 1 }
                    }
                    proxySourceTested += pending.count
                    proxySourceAdded += additions.count
                    if !additions.isEmpty {
                        proxyConfiguration.entries.append(contentsOf: additions)
                        proxyTestResults.merge(results) { _, new in new }
                        _ = persist(reportError: false)
                    }
                    pending.removeAll(keepingCapacity: true)
                    lastFlush = ProcessInfo.processInfo.systemUptime
                }
                await ProxyManager.testBatch(candidates, concurrencyLimit: concurrency, test: { entry in
                    await self.testPoolProxy(entry, configuration: testConfiguration)
                }, completed: { entry, result in
                    pending.append((entry, result))
                    if ProcessInfo.processInfo.systemUptime - lastFlush >= 0.2 || !self.proxyConfiguration.entries.contains(where: \.enabled) { flush() }
                })
                flush()
                try Task.checkCancellation()
                proxySourceStatus = "更新完成：测速 \(proxySourceTested) 个，新增 \(proxySourceAdded) 个，丢弃 \(proxySourceRejected) 个。"
                if !proxySourceErrors.isEmpty { proxySourceStatus += "\(proxySourceErrors.count) 个来源下载失败，其他来源已处理。" }
                log("后台代理\(proxySourceStatus)")
            } catch {
                proxySourceStatus = Task.isCancelled || error is CancellationError ? "本次更新已停止，已通过测速的代理保留。" : "本次代理更新未完成，下次自动重试。"
            }
        }
    }

    func stopProxySourceRefresh() { proxySourceTask?.cancel() }
}
