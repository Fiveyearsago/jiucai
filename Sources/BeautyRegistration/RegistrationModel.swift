import AppKit
import Combine
import RegistrationCore

@MainActor
final class RegistrationModel: ObservableObject {
    @Published var configuration = TaskConfiguration()
    @Published var proxyConfiguration = ProxyConfiguration()
    private let rememberedPassword = RememberedPassword()
    private var passwordObserver: AnyCancellable?
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
    @Published var detail = "设置账号信息，点击开始即可运行注册流程。"
    @Published var currentUsername = ""
    @Published var step = 0
    @Published var tab = "registration"
    @Published var manualCode = ""
    @Published var alert: String?
    @Published var acknowledgedMailboxTerms = false
    @Published var completedInRun = 0
    @Published var totalInRun = 0
    @Published var storageAvailable = true
    @Published var pagesOpened = false
    @Published var headerVariantStrategy = HeaderVariantStrategy(rawValue: UserDefaults.standard.string(forKey: "headerVariantStrategy") ?? "") ?? .fixed {
        didSet { UserDefaults.standard.set(headerVariantStrategy.rawValue, forKey: "headerVariantStrategy") }
    }
    @Published var headerConfiguration = RequestHeaderConfiguration.restore() {
        didSet {
            headerConfiguration.save()
            // Push overrides into any already-open page without reloading.
            Task { await registrationPage.updateHeaderOverrides() }
        }
    }
    var useCompatibilityHeaders: Bool {
        get { headerConfiguration.mode == .safari }
        set { headerConfiguration.mode = newValue ? .safari : .webKit }
    }

    let registrationPage = BrowserPane(host: "api.jiucaihezi.studio")
    let mailboxPage = BrowserPane(host: "fviainboxes.com")
    let store: JournalStore
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    private var submissionAttempted = false
    private var persistenceError: String?

    var journal: Journal {
        var value = Journal(); value.configuration = configuration; value.records = records
        value.proxyConfiguration = proxyConfiguration; return value
    }
    var successCount: Int { records.filter { $0.status == .succeeded }.count }
    var uncertainCount: Int { records.filter { $0.status == .uncertain }.count }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = JournalStore(directory: base.appendingPathComponent("BeautyRegistration", isDirectory: true))
        passwordObserver = rememberedPassword.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        do {
            var value = try store.load(); value.recoverInterruptedRun()
            configuration = value.configuration; records = value.records
            proxyConfiguration = value.proxyConfiguration
            try store.save(value)
        } catch {
            storageAvailable = false
            alert = "无法读取或写入本地记录。原文件已保留，修复后重启应用：\(store.fileURL.path)"
        }
        registrationPage.onNetworkRecord = { [weak self] entry in
            guard let self, self.isRunning, let id = self.activeID,
                  let i = self.records.firstIndex(where: { $0.id == id }) else { return }
            self.records[i].network.append(entry)
            if self.records[i].network.count > 100 { self.records[i].network.removeFirst(self.records[i].network.count - 100) }
            _ = self.persist()
        }
        registrationPage.onRegistration = { [weak self] response in
            guard let self, let id = self.activeID, self.submissionAttempted else { return }
            if response["success"] as? Bool == true {
                self.update(id, status: .succeeded, note: "网站注册接口已明确返回成功。")
            }
        }
    }

    func openPages() {
        guard !isRunning else { return }
        pagesOpened = true
        registrationPage.load(configuration.registrationURL, headers: headerConfiguration)
        mailboxPage.load(URL(string: "https://fviainboxes.com")!)
    }

    func start() {
        guard !isRunning, storageAvailable else { return }
        do { try configuration.validate(password: password) } catch { alert = error.localizedDescription; return }
        guard acknowledgedMailboxTerms else { alert = "请先阅读邮箱服务条款，并勾选已阅读选项。"; return }
        let config = configuration
        let runPassword = password
        let batch = RegistrationBatch(configuration: config, records: records)
        guard batch.count > 0 else { alert = "这些用户名已有成功或待核对记录，请调整起始编号。"; return }
        guard persist() else { return }
        isRunning = true; isPaused = false; completedInRun = 0; totalInRun = batch.count
        persistenceError = nil
        let generator = HeaderVariantGenerator(strategy: headerVariantStrategy, base: headerConfiguration)
        if !batch.blockedIndices.isEmpty { log("跳过 \(batch.blockedIndices.count) 个已成功或待核对账号。") }
        log("开始串行任务，共 \(batch.count) 个账号。")
        log("请求头配置：\(headerConfiguration.title)。")
        if headerVariantStrategy != .fixed { log("差异化策略：\(headerVariantStrategy.title)。") }
        task = Task {
            var stopped = false
            // Track consecutive failures per proxy ID within this run.
            // After maxProxyFailures consecutive failures the proxy is skipped for the rest of the run.
            var proxyFailCounts: [UUID: Int] = [:]
            let maxProxyFailures = 2
            var indices = batch.indices.filter { !batch.blockedIndices.contains($0) }[...]
            while let index = indices.first {
                indices = indices.dropFirst()
                let variantHeaders = generator.variant(forIndex: index)
                // Create a record only when its account is about to run, not for the entire range.
                let record = AccountRecord(username: config.username(index), email: config.email(index))
                let id = record.id
                records.append(record)
                activeID = id; submissionAttempted = false; currentUsername = record.username; manualCode = ""
                // Apply proxy from pool if configured — rebuild WebView with new dataStore.
                let activeProxy = proxyConfiguration.proxy(forCompletedCount: completedInRun)
                registrationPage.rebuildWebView(proxy: activeProxy)
                if let proxy = activeProxy {
                    log("代理已切换：\(proxy.displayName)，正在检测出口 IP…")
                    if let info = await ProxyManager.exitInfo(through: proxy) {
                        log("出口 IP：\(info.summary)")
                        appendLog(id, "出口 IP：\(info.summary)")
                    } else {
                        log("出口 IP 检测失败，代理可能不可用。")
                    }
                }
                do {
                    try Task.checkCancellation()
                    update(id, status: .running, note: "正在准备注册。")
                    try await register(record, config: config, password: runPassword, headers: variantHeaders)
                    completedInRun += 1
                    if completedInRun < totalInRun {
                        step = 5; phase = "等待下一个账号"
                        for remaining in (1...config.intervalSeconds).reversed() {
                            detail = "\(remaining) 秒后继续，\(completedInRun)/\(totalInRun) 已完成。"
                            try await tick()
                        }
                    }
                } catch {
                    let cancelled = error is CancellationError
                    let is429 = (error as? ClientError)?.localizedDescription.contains("HTTP 429") == true
                    if records.first(where: {$0.id == id})?.status != .succeeded {
                        update(id, status: submissionAttempted ? .uncertain : (cancelled ? .cancelled : .failed),
                               note: submissionAttempted ? "提交后未取得明确结果，请在官网核对后处理。" : (cancelled ? "用户已停止任务。" : safeError(error)))
                    }
                    if !cancelled { alert = safeError(error); log("任务已停下：\(safeError(error))") }
                    // Track consecutive failures on the active proxy; disable it after maxProxyFailures.
                    if let proxy = proxyConfiguration.proxy(forCompletedCount: completedInRun), !cancelled {
                        proxyFailCounts[proxy.id, default: 0] += 1
                        if proxyFailCounts[proxy.id, default: 0] >= maxProxyFailures {
                            if let i = proxyConfiguration.entries.firstIndex(where: { $0.id == proxy.id }) {
                                proxyConfiguration.entries[i].enabled = false
                                log("代理 \(proxy.displayName) 连续失败 \(maxProxyFailures) 次，本次任务已跳过该代理。")
                            }
                            proxyFailCounts.removeValue(forKey: proxy.id)
                        }
                    }
                    // Reset startIndex to the failed account so the next run resumes from here.
                    configuration.startIndex = index
                    _ = persist()
                    // If cooldown is configured and not cancelled, wait and retry this index.
                    if !cancelled && config.cooldownMinutes > 0 {
                        let totalSeconds = config.cooldownMinutes * 60
                        step = 5; phase = "冷却等待"
                        let reason = is429 ? "429" : "报错"
                        log("遇到\(reason)，等待 \(config.cooldownMinutes) 分钟后自动重试 \(config.username(index))。")
                        do {
                            for remaining in (1...totalSeconds).reversed() {
                                let m = remaining / 60, s = remaining % 60
                                detail = "冷却中，\(m):\(String(format: "%02d", s)) 后重试 \(config.username(index))（\(reason)）。"
                                try await tick()
                            }
                        } catch {
                            stopped = true; break
                        }
                        // Re-insert this index at the front to retry it.
                        indices = ([index] + indices).dropFirst(0)
                        alert = nil
                        continue
                    }
                    stopped = true
                    break
                }
            }
            isRunning = false; isPaused = false
            phase = stopped ? "任务已停止" : "任务完成"
            detail = "本次已完成 \(completedInRun)/\(totalInRun) 个账号。可在注册记录中查看结果。"
            if !stopped { step = 5; configuration.startIndex = batch.indices.upperBound; _ = persist() }
            task = nil
        }
    }

    private func register(_ record: AccountRecord, config: TaskConfiguration, password: String, headers: RequestHeaderConfiguration) async throws {
        step = 1; phase = "打开网页"; detail = "正在载入注册页和邮箱页。"; tab = "registration"
        pagesOpened = true
        if headers != headerConfiguration {
            let ua = headers.effectiveUserAgent.map { String($0.prefix(60)) } ?? "默认"
            let lang = headers.effectiveAcceptLanguage ?? "默认"
            log("\(record.username)：差异化请求头 — UA: \(ua) | Lang: \(lang)")
        }
        appendLog(record.id, "开始注册流程。UA: \(headers.effectiveUserAgent.map { String($0.prefix(80)) } ?? "默认")")
        registrationPage.load(config.registrationURL, headers: headers)
        mailboxPage.load(URL(string: "https://fviainboxes.com")!)
        try await waitFor(timeout: 150, timeoutMessage: "网页未能加载，请检查网络后重新开始。") {
            if let error = self.registrationPage.navigationError ?? self.mailboxPage.navigationError { throw ClientError.message(error) }
            let reg = await self.registrationPage.snapshot()
            let mail = await self.mailboxPage.snapshot()
            if reg["regReady"] as? Bool == true, let status = mail["mailStatus"] as? String, !status.isEmpty {
                self.tab = "mailbox"
                self.detail = status
            }
            return reg["regReady"] as? Bool == true && mail["mailReady"] as? Bool == true
        }
        try await gate()
        let filled = try await registrationPage.call("fillRegistration", arguments: ["username": record.username, "email": record.email, "password": password]) as? [String: Any]
        step = 2; phase = "准备邮箱"; detail = "\(record.email) · 如需人机验证，请在下方邮箱页完成。"; tab = "mailbox"
        try await waitFor(timeout: 120, timeoutMessage: "邮箱域名或输入控件尚未就绪，请检查邮箱页的域名和人机验证状态。") {
            let result = try await self.mailboxPage.call("prepareMailbox", arguments: ["username": record.username]) as? String
            if result == "prepared" { return true }
            let state = await self.mailboxPage.snapshot()
            if let status = state["mailStatus"] as? String, !status.isEmpty { self.detail = status }
            return false
        }
        if filled?["requiresEmail"] as? Bool == true {
            _ = try await mailboxPage.call("armMailbox")
            step = 3; phase = "发送验证码"; detail = "正在通过官网发送验证邮件。"; tab = "registration"
            try await VerificationRetry.send(attempt: {
                self.phase = "发送验证码"; self.detail = "正在通过官网发送验证邮件。"
                self.registrationPage.verification = nil
                try await self.clickWhenReady("sendCode", explanation: "请在注册页完成人机验证，或检查邮箱字段，然后点击继续。")
                try await self.waitFor(timeout: 45, pollEvery: 0.2, timeoutMessage: "发送验证码的结果未确认，请检查官网提示；本次不会自动重发。") {
                    self.registrationPage.verification != nil
                }
                let result = self.registrationPage.verification ?? [:]
                let vStatus = result["status"] as? Int ?? 0
                let vMsg = result["message"] as? String ?? ""
                self.appendLog(record.id, "发送验证码 → HTTP \(vStatus)\(vMsg.isEmpty ? "" : "：\(vMsg)")")
                return result
            }, wait: { seconds, retry in
                self.phase = "等待发送冷却"
                self.log("\(record.username)：发送验证码遇到 HTTP 429，等待 \(seconds) 秒后重试（\(retry)/\(VerificationRetry.maximumRetries)）。")
                if let raw = ServerFailure.rawBody429(self.registrationPage.verification) {
                    self.log("\(record.username)：验证码 429 原始响应 → \(raw)")
                }
                for remaining in (1...seconds).reversed() {
                    self.detail = "发送过于频繁，\(remaining) 秒后重试当前账号（\(retry)/\(VerificationRetry.maximumRetries)）。"
                    try await self.tick()
                }
            })
            _ = try await mailboxPage.call("beginMailboxPolling")
            phase = "等待邮件验证码"; detail = "验证码已发送，2 秒后获取邮件。"; tab = "mailbox"
            log("\(record.username)：验证码已发送，2 秒后开始获取邮件。")
            var code = ""
            var mailboxPolls = 0
            while true {
                try await gate()
                if manualCode.range(of: "^[A-Za-z0-9]{6}$", options: .regularExpression) != nil { code = manualCode; break }
                if let error = mailboxPage.navigationError { throw ClientError.message(error) }
                let result = try await mailboxPage.call("pollMailbox") as? String
                if result == "clicked" {
                    mailboxPolls += 1
                    detail = "每 2 秒获取邮件，已获取 \(mailboxPolls) 次；收到验证码后自动继续。"
                }
                let state = await mailboxPage.snapshot()
                if let problem = state["problem"] as? String, !problem.isEmpty {
                    try await attention(problem, tab: "mailbox")
                    _ = try await mailboxPage.call("beginMailboxPolling")
                }
                code = state["code"] as? String ?? ""
                if code.range(of: "^[A-Za-z0-9]{6}$", options: .regularExpression) != nil { break }
                try await tick(nanoseconds: 200_000_000)
            }
            _ = try await registrationPage.call("fillCode", arguments: ["code": code])
            manualCode = ""
            log("\(record.username)：已填入验证码。")
        }
        step = 4; phase = "提交注册"; detail = "等待网站返回明确结果。"; tab = "registration"
        try await gate()
        // Journal is committed before the request. A crash can never trigger an automatic resubmission.
        submissionAttempted = true
        update(record.id, status: .submitting, note: "准备提交，等待网站回执。")
        if let persistenceError { submissionAttempted = false; throw ClientError.message(persistenceError) }
        var clicked = try await registrationPage.call("submit") as? String
        while clicked != "clicked" {
            submissionAttempted = false
            update(record.id, status: .running, note: "等待完成网页验证或条款确认。")
            try await attention("请在注册页阅读并确认网站条款、完成人机验证，然后点击继续。", tab: "registration")
            submissionAttempted = true
            update(record.id, status: .submitting, note: "准备提交，等待网站回执。")
            if let persistenceError { submissionAttempted = false; throw ClientError.message(persistenceError) }
            clicked = try await registrationPage.call("submit") as? String
        }
        try await waitFor(timeout: 60, timeoutMessage: "提交后未收到明确回执，账号已标记为待核对，请勿直接重复注册。") {
            self.registrationPage.registration != nil
        }
        guard registrationPage.registration?["success"] as? Bool == true else {
            submissionAttempted = false
            if let raw = ServerFailure.rawBody429(registrationPage.registration) {
                log("\(record.username)：注册 429 原始响应 → \(raw)")
            }
            let errMsg = ServerFailure.describe(registrationPage.registration, operation: "注册")
            appendLog(record.id, "提交结果 → \(errMsg)")
            throw ClientError.message(errMsg)
        }
        appendLog(record.id, "提交结果 → HTTP \(registrationPage.registration?["status"] as? Int ?? 200) 注册成功。")
        update(record.id, status: .succeeded, note: "网站注册接口已明确返回成功。")
        log("\(record.username)：注册成功。")
        step = 5; phase = "保存结果"
        // Only capture the post-registration login page, never a form containing credentials.
        for _ in 0..<10 {
            try await tick()
            if registrationPage.webView.url?.path == "/sign-in" {
                let url = store.directory.appendingPathComponent("\(record.username)-\(record.id.uuidString).png")
                do {
                    try await registrationPage.saveScreenshot(to: url)
                    if let i = records.firstIndex(where: {$0.id == record.id}) { records[i].screenshot = url.path; _ = persist() }
                } catch { log("注册成功，结果截图未保存。") }
                break
            }
        }
    }

    private func clickWhenReady(_ method: String, explanation: String) async throws {
        while true {
            try await gate()
            if (try await registrationPage.call(method) as? String) == "clicked" { return }
            try await attention(explanation, tab: "registration")
        }
    }
    private func waitFor(timeout: Int, pollEvery: TimeInterval = 1, timeoutMessage: String, condition: () async throws -> Bool) async throws {
        for _ in 0..<Int(ceil(Double(timeout) / pollEvery)) {
            try await gate()
            if try await condition() { return }
            try await tick(nanoseconds: UInt64(pollEvery * 1_000_000_000))
        }
        throw ClientError.message(timeoutMessage)
    }
    private func gate() async throws {
        try Task.checkCancellation()
        if let persistenceError { throw ClientError.message(persistenceError) }
        while isPaused { try await Task.sleep(nanoseconds: 250_000_000); try Task.checkCancellation() }
    }
    private func tick(nanoseconds: UInt64 = 1_000_000_000) async throws { try await gate(); try await Task.sleep(nanoseconds: nanoseconds); try Task.checkCancellation() }
    private func attention(_ message: String, tab: String) async throws {
        detail = message; self.tab = tab; isPaused = true; log(message)
        try await gate()
    }
    func togglePause() { isPaused.toggle() }
    func stop() { task?.cancel(); isPaused = false; detail = "正在停止。已提交的请求仍可能在服务器完成。" }
    private func safeError(_ error: Error) -> String {
        if let client = error as? ClientError { return client.localizedDescription }
        return "网页操作未完成，请检查页面状态后重试。"
    }
    private func update(_ id: UUID, status: RecordStatus, note: String) {
        guard let i = records.firstIndex(where: {$0.id == id}) else { return }
        records[i].status = status; records[i].note = note; records[i].updatedAt = Date(); _ = persist()
    }
    private func appendLog(_ id: UUID, _ text: String) {
        guard let i = records.firstIndex(where: {$0.id == id}) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        records[i].logs.append("\(formatter.string(from: Date()))  \(text)")
        _ = persist()
    }
    @discardableResult private func persist() -> Bool {
        do { try store.save(journal); return true }
        catch { persistenceError = "记录写入失败，任务已停止以避免丢失提交状态。"; alert = persistenceError; return false }
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
