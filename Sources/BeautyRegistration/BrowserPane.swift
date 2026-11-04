import AppKit
import SwiftUI
import WebKit
import RegistrationCore

@MainActor
final class BrowserPane: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private(set) var webView: WKWebView
    let allowedHost: String
    @Published var loading = false
    @Published var navigationError: String?
    @Published private(set) var loadingTimeoutError: PageLoadTimeout?
    var loadingTimeout: TimeInterval
    @Published private(set) var appliedHeaderMode: RequestHeaderMode?
    @Published private(set) var appliedHeaders: RequestHeaderConfiguration?
    @Published private(set) var currentUserAgent = ""
    @Published private(set) var requestObservations: [RequestHeaderObservation] = []
    @Published private(set) var networkRecords: [NetworkRecord] = []
    /// Incremented each time the underlying WKWebView is replaced, so SwiftUI
    /// can re-create EmbeddedBrowser and pick up the new instance.
    @Published private(set) var webViewID = UUID()
    var verification: [String: Any]?
    var registration: [String: Any]?
    var onRegistration: (([String: Any]) -> Void)?
    var onNetworkRecord: ((NetworkRecord) -> Void)?
    private var documentID = UUID().uuidString
    private var compatibilityHeaders = false
    private var loadingTimeoutTask: Task<Void, Never>?
    private var activeLoadID: UUID?
    private var activeNavigation: WKNavigation?
    private var retiredNavigations: [WKNavigation] = []

    init(host: String, loadingTimeout: TimeInterval = PageLoadTimeout.defaultSeconds) {
        allowedHost = host
        self.loadingTimeout = loadingTimeout
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        config.userContentController.add(self, name: "beauty")
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        // Lets Safari › 开发 › <本机> attach its full Web Inspector to this page.
        if #available(macOS 13.3, *) { webView.isInspectable = true }
    }

    func load(_ url: URL, compatibilityHeaders: Bool = false) {
        load(url, headers: compatibilityHeaders ? RequestHeaderConfiguration() : .webKit)
    }

    func load(_ url: URL, headers: RequestHeaderConfiguration) {
        guard url.scheme == "https", url.host == allowedHost else { return }
        configureHeaders(headers)
        stopLoading()
        verification = nil; registration = nil; navigationError = nil; loadingTimeoutError = nil
        beginLoading()
        installBridge()
        var request = URLRequest(url: url, timeoutInterval: effectiveLoadingTimeout)
        if let language = appliedHeaders?.language.value { request.setValue(language, forHTTPHeaderField: "Accept-Language") }
        trackNavigation(webView.load(request))
    }

    private var effectiveLoadingTimeout: TimeInterval {
        loadingTimeout.isFinite && loadingTimeout > 0 ? loadingTimeout : PageLoadTimeout.defaultSeconds
    }

    private func beginLoading() {
        // Redirects share the same deadline while the page remains continuously loading.
        guard activeLoadID == nil, loadingTimeoutError == nil else { return }
        let id = UUID()
        activeLoadID = id
        loading = true
        let timeout = effectiveLoadingTimeout
        let started = ProcessInfo.processInfo.systemUptime
        loadingTimeoutTask = Task { [weak self] in
            var remaining = timeout
            do {
                repeat {
                    try await Task.sleep(nanoseconds: UInt64(min(remaining, 3_600) * 1_000_000_000))
                    remaining = timeout - (ProcessInfo.processInfo.systemUptime - started)
                } while remaining > 0
            } catch { return }
            guard let self, self.activeLoadID == id, self.loading else { return }
            let error = PageLoadTimeout(seconds: timeout)
            self.loadingTimeoutError = error
            self.navigationError = error.localizedDescription
            self.stopLoading()
        }
    }

    private func finishLoading() {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = nil
        activeLoadID = nil
        loading = false
    }

    func stopLoading() {
        finishLoading()
        retireNavigation()
        webView.stopLoading()
    }

    private func retireNavigation() {
        if let activeNavigation {
            retiredNavigations.append(activeNavigation)
            if retiredNavigations.count > 32 { retiredNavigations.removeFirst() }
        }
        activeNavigation = nil
    }

    @discardableResult
    private func trackNavigation(_ navigation: WKNavigation?) -> Bool {
        guard let navigation else { return true }
        guard !retiredNavigations.contains(where: { $0 === navigation }) else { return false }
        if activeNavigation !== navigation {
            retireNavigation()
            activeNavigation = navigation
        }
        return true
    }

    private func isCurrentNavigation(_ navigation: WKNavigation?) -> Bool {
        navigation == nil || navigation === activeNavigation
    }

    private func configureHeaders(_ selected: RequestHeaderConfiguration) {
        let selected = allowedHost == "api.jiucaihezi.studio" ? selected : .webKit
        let mode = selected.mode
        appliedHeaders = selected
        compatibilityHeaders = mode == .safari
        appliedHeaderMode = mode
        webView.customUserAgent = mode.userAgent
        currentUserAgent = mode.userAgent ?? ""
    }

    /// Push updated header overrides into the live page without reloading.
    /// Call this after `appliedHeaders` changes while a page is already open.
    func clearNetworkRecords() { networkRecords.removeAll() }

    /// Rebuild the underlying WebView with an optional proxy. Call before each registration run.
    /// On macOS < 14 the proxy parameter is ignored (no-op proxy change, no store rebuild).
    func rebuildWebView(proxy: ProxyEntry? = nil) {
        finishLoading()
        retireNavigation()
        documentID = UUID().uuidString
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "beauty")
        webView.stopLoading()
        let wkConfig = WKWebViewConfiguration()
        if #available(macOS 14.0, *) {
            let store = WKWebsiteDataStore.nonPersistent()
            if let entry = proxy, let proxyCfg = ProxyManager.configuration(for: entry) {
                store.proxyConfigurations = [proxyCfg]
            }
            wkConfig.websiteDataStore = store
        } else {
            wkConfig.websiteDataStore = .nonPersistent()
        }
        wkConfig.preferences.javaScriptCanOpenWindowsAutomatically = false
        wkConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        wkConfig.userContentController.add(self, name: "beauty")
        let newView = WKWebView(frame: webView.frame, configuration: wkConfig)
        newView.navigationDelegate = self
        newView.uiDelegate = self
        newView.allowsBackForwardNavigationGestures = true
        newView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { newView.isInspectable = true }
        webView = newView
        webViewID = UUID()  // signals SwiftUI to re-create EmbeddedBrowser
        appliedHeaders = nil; appliedHeaderMode = nil; currentUserAgent = ""
        verification = nil; registration = nil; navigationError = nil; loadingTimeoutError = nil; loading = false
    }

    private func addNetworkRecord(_ record: NetworkRecord) {
        networkRecords.insert(record, at: 0)
        if networkRecords.count > 100 { networkRecords.removeLast(networkRecords.count - 100) }
        onNetworkRecord?(record)
    }

    func updateHeaderOverrides() async {
        guard webView.url?.host == allowedHost,
              let overrides = try? JSONSerialization.data(withJSONObject: appliedHeaders?.overrides ?? [:]),
              let json = String(data: overrides, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript("if (typeof beautyHeaderOverrides !== 'undefined') { beautyHeaderOverrides = \(json); }")
    }

    func refreshUserAgent() async {
        let expectedDocument = documentID
        let expectedMode = appliedHeaderMode
        if let agent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String,
           documentID == expectedDocument, appliedHeaderMode == expectedMode {
            currentUserAgent = agent
        }
    }

    private func installBridge(prelude: String = "") {
        documentID = UUID().uuidString
        // Read bundled adapters at each navigation, so adapter-only updates can
        // take effect on the next task without clearing the in-memory password.
        let bridge = (try? String(contentsOf: Bundle.module.url(forResource: "bridge", withExtension: "js")!)) ?? ""
        let mailboxCleanup = (try? String(contentsOf: Bundle.module.url(forResource: "mailbox-cleanup", withExtension: "js")!)) ?? ""
        let overrides = (try? JSONSerialization.data(withJSONObject: appliedHeaders?.overrides ?? [:])) ?? Data("{}".utf8)
        let source = prelude + "\nconst beautyDocumentID = '\(documentID)';\nconst beautyCompatibilityHeaders = \(compatibilityHeaders);\nvar beautyHeaderOverrides = \(String(decoding: overrides, as: UTF8.self));\n" + bridge
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if allowedHost == "fviainboxes.com" {
            controller.addUserScript(WKUserScript(source: mailboxCleanup, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    #if DEBUG
    func loadFixture(_ html: String, baseURL: URL, compatibilityHeaders: Bool = false) {
        loadFixture(html, baseURL: baseURL, headers: compatibilityHeaders ? RequestHeaderConfiguration() : .webKit)
    }
    func loadFixture(_ html: String, baseURL: URL, headers: RequestHeaderConfiguration, prelude: String = "") {
        stopLoading()
        verification = nil; registration = nil; navigationError = nil; loadingTimeoutError = nil
        configureHeaders(headers)
        installBridge(prelude: prelude)
        beginLoading()
        trackNavigation(webView.loadHTMLString(html, baseURL: baseURL))
    }
    #endif

    func call(_ method: String, arguments: [String: Any] = [:]) async throws -> Any {
        guard webView.url?.host == allowedHost else { throw ClientError.message("网页尚未加载完成。") }
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed])
        let json = String(decoding: data, as: UTF8.self)
        // WKWebView keeps its old DOM alive while a reload is starting. Do not
        // treat that old form as ready or write credentials into a discarded page.
        do { return try await webView.evaluateJavaScript("""
        (() => {
          const bridge = window.beautyBridge;
          if (!bridge || bridge.snapshot().documentID !== '\(documentID)') {
            throw new Error('网页仍在刷新，请等待新的页面载入。');
          }
          return bridge.\(method)(\(json));
        })()
        """) as Any } catch {
            if error is CancellationError { throw error }
            let label: String
            switch method {
            case "prepareMailbox", "armMailbox": label = "准备邮箱"
            case "fillRegistration": label = "填写注册信息"
            case "sendCode": label = "发送验证码"
            case "scanMailbox", "beginMailboxPolling", "pollMailbox": label = "读取邮件"
            case "fillCode": label = "填写验证码"
            case "submit": label = "提交注册"
            default: label = "读取网页状态"
            }
            let raw = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            let known = ["网页仍在刷新，请等待新的页面载入。", "字段尚未出现，请等待网页加载。", "不在指定注册页。", "邮箱来源不匹配。", "请将邮箱域名切换为 fviainboxes.com。", "未找到验证码输入框。", "验证码必须是 6 位字母或数字。"]
            if let reason = known.first(where: {raw.contains($0)}) {
                throw ClientError.message("\(label)：\(reason)")
            }
            // Do not persist arbitrary page exceptions: they can contain input values.
            throw ClientError.message("\(label)失败（WebKit 错误 \((error as NSError).code)），请检查页面状态。")
        }
    }

    func snapshot() async -> [String: Any] { (try? await call("snapshot")) as? [String: Any] ?? [:] }

    func saveScreenshot(to url: URL) async throws {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            throw ClientError.message("截图生成失败。")
        }
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == allowedHost,
              let value = message.body as? [String: Any],
              value["documentID"] as? String == documentID,
              let kind = value["kind"] as? String else { return }
        if kind == "pageReady", navigationError == nil, loadingTimeoutError == nil { finishLoading() }
        if kind == "verification" { verification = value }
        if kind == "registration" { registration = value; onRegistration?(value) }
        if kind == "requestHeaders", allowedHost == "api.jiucaihezi.studio",
           let path = value["path"] as? String, RequestHeaderObservation.paths.contains(path),
           let method = value["method"] as? String, ["GET", "POST", "HEAD", "OPTIONS"].contains(method),
           let transport = value["transport"] as? String, ["fetch", "XMLHttpRequest"].contains(transport) {
            let raw = value["headers"] as? [[String: String]] ?? []
            let headers = RequestHeaderObservation.names.compactMap { name -> ObservedRequestHeader? in
                guard let item = raw.first(where: { $0["name"] == name }), let text = item["value"] else { return nil }
                let source = ["网页设置", "客户端配置", "浏览器标识"].contains(item["source"] ?? "") ? item["source"]! : "网页设置"
                return ObservedRequestHeader(name: name, value: String(text.prefix(500)), source: source)
            }
            recordRequest(method: method, path: path, transport: transport, headers: headers)
        }
        if kind == "networkRecord", allowedHost == "api.jiucaihezi.studio",
           let path = value["path"] as? String,
           let method = value["method"] as? String,
           let status = value["status"] as? Int {
            let transport = value["transport"] as? String ?? "fetch"
            func parseHeaders(_ key: String) -> [NetworkHeader] {
                (value[key] as? [[String: Any]] ?? []).compactMap { item -> NetworkHeader? in
                    guard let name = item["name"] as? String, let val = item["value"] as? String else { return nil }
                    return NetworkHeader(name: name, value: val, source: item["source"] as? String ?? "")
                }
            }
            let record = NetworkRecord(
                method: method, path: path, transport: transport, status: status,
                requestHeaders: parseHeaders("requestHeaders"),
                responseHeaders: parseHeaders("responseHeaders"),
                responseBody: value["responseBody"] as? String ?? "",
                retryAfter: value["retryAfter"] as? String
            )
            addNetworkRecord(record)
        }
    }

    private func recordRequest(method: String, path: String, transport: String, headers: [ObservedRequestHeader]) {
        requestObservations.insert(RequestHeaderObservation(method: method, path: path, transport: transport,
            profile: appliedHeaders?.title ?? "默认 WebKit", headers: headers), at: 0)
        if requestObservations.count > 20 { requestObservations.removeLast(requestObservations.count - 20) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, trackNavigation(navigation) else { return }
        beginLoading()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, isCurrentNavigation(navigation) else { return }
        finishLoading()
        Task { await refreshUserAgent() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, isCurrentNavigation(navigation) else { return }
        failed(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, isCurrentNavigation(navigation) else { return }
        failed(error)
    }
    private func failed(_ error: Error) {
        // Cancellation of a replaced request can arrive after the next load has started.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if (error as NSError).code == NSURLErrorTimedOut {
            let timeout = PageLoadTimeout(seconds: effectiveLoadingTimeout)
            loadingTimeoutError = timeout
            navigationError = timeout.localizedDescription
            finishLoading()
            return
        }
        finishLoading()
        navigationError = "网页加载失败：\(ProxyManager.networkFailureDescription(error))。"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        finishLoading()
        navigationError = "网页进程已退出。"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if allowedHost == "api.jiucaihezi.studio", url.host == allowedHost,
           RequestHeaderObservation.paths.contains(url.path) {
            let headers = RequestHeaderObservation.names.compactMap { name -> ObservedRequestHeader? in
                guard var value = action.request.value(forHTTPHeaderField: name) else { return nil }
                if name == "Origin" || name == "Referer" {
                    guard let address = URLComponents(string: value), let scheme = address.scheme, let host = address.host else { return nil }
                    value = "\(scheme)://\(host)" + (RequestHeaderObservation.paths.contains(address.path) ? address.path : "/…")
                }
                return ObservedRequestHeader(name: name, value: String(value.prefix(500)), source: "导航请求")
            }
            recordRequest(method: action.request.httpMethod ?? "GET", path: url.path, transport: "网页导航", headers: headers)
        }
        if url.scheme == "about" || (url.scheme == "https" && url.host == allowedHost) { decisionHandler(.allow); return }
        // Only user-clicked external links leave the embedded browser.
        if action.navigationType == .linkActivated && ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           response.url?.host == allowedHost, response.statusCode >= 400 {
            navigationError = "网页无法访问（HTTP \(response.statusCode)）。"
        }
        if allowedHost == "api.jiucaihezi.studio", navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           let url = response.url, url.host == allowedHost {
            let hidden: Set<String> = ["set-cookie", "cookie", "authorization"]
            let headers = response.allHeaderFields.compactMap { key, value -> NetworkHeader? in
                let name = String(describing: key)
                guard !hidden.contains(name.lowercased()) else { return nil }
                return NetworkHeader(name: name, value: String(String(describing: value).prefix(500)))
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            let requestHeaders = requestObservations.first(where: { $0.transport == "网页导航" && $0.path == url.path })?
                .headers.map { NetworkHeader(name: $0.name, value: $0.value, source: $0.source) } ?? []
            addNetworkRecord(NetworkRecord(method: "GET", path: url.path, transport: "网页导航", status: response.statusCode,
                requestHeaders: requestHeaders, responseHeaders: headers, responseBody: "",
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")))
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView else { return nil }
        if let url = navigationAction.request.url, url.scheme == "https", navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        return nil
    }
}

struct EmbeddedBrowser: NSViewRepresentable {
    @ObservedObject var pane: BrowserPane
    func makeNSView(context: Context) -> WKWebView { pane.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
