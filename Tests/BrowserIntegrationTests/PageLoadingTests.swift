import XCTest
import WebKit
import Network
import RegistrationCore
@testable import BeautyRegistration

final class PageLoadingTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The loading watchdog did not fire")
    }

    @MainActor
    private func withStalledImage(host: String = "api.jiucaihezi.studio", body: String,
                                  check: (BrowserPane) async throws -> Void) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let listening = expectation(description: "Local slow resource server is listening")
        let requested = expectation(description: "WebKit requested the deliberately stalled image")
        let connections = HeldResourceConnections()
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                connections.values.append(connection)
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                    requested.fulfill()
                    // Deliberately leave the response open, as a stalled page asset would.
                }
            }
        }
        listener.start(queue: .main)
        defer { connections.values.forEach { $0.cancel() }; listener.cancel() }
        await fulfillment(of: [listening], timeout: 2)
        let port = try XCTUnwrap(listener.port)
        let pane = BrowserPane(host: host, loadingTimeout: 2)
        defer { pane.stopLoading() }
        pane.loadFixture("""
        <html><body>\(body)<img src="http://127.0.0.1:\(port.rawValue)/stalled-image"></body></html>
        """, baseURL: URL(string: "https://\(host)/sign-up")!)
        await fulfillment(of: [requested], timeout: 2)
        try await check(pane)
    }

    @MainActor
    func testUsableRegistrationFormDoesNotWaitForHangingSubresource() async throws {
        try await withStalledImage(body: "<input name='username'><input name='password'><input name='confirmPassword'>") { pane in
            let state = await pane.snapshot()
            XCTAssertEqual(state["regReady"] as? Bool, true)
            XCTAssertTrue(pane.webView.isLoading, "The fixture must keep WebKit's full-page load pending")
            // Observe beyond the configured limit: a usable form must never trigger proxy deletion.
            try await Task.sleep(nanoseconds: 2_100_000_000)
            XCTAssertNil(pane.loadingTimeoutError, "A stalled nonessential image must not discard a healthy proxy")
            XCTAssertNil(pane.navigationError)
            XCTAssertFalse(pane.loading, "The loading overlay must follow form readiness")
        }
    }

    @MainActor
    func testIncompleteRegistrationFormWaitsForVisibleEnabledMandatoryFields() async throws {
        try await withStalledImage(body: "<input name='username'><input name='confirmPassword' style='display:none'>") { pane in
            var state = await pane.snapshot()
            XCTAssertEqual(state["regReady"] as? Bool, false, "Missing password and hidden confirmation are not usable")
            XCTAssertTrue(pane.loading)
            _ = try await pane.webView.evaluateJavaScript("""
            const password = document.createElement('input'); password.name = 'password'; password.disabled = true;
            document.body.appendChild(password);
            document.querySelector('input[name=confirmPassword]').style.display = 'block';
            """)
            state = await pane.snapshot()
            XCTAssertEqual(state["regReady"] as? Bool, false, "Disabled required fields are not usable")
            _ = try await pane.webView.evaluateJavaScript("document.querySelector('input[name=password]').disabled = false")
            try await self.waitUntil { !pane.loading }
            state = await pane.snapshot()
            XCTAssertEqual(state["regReady"] as? Bool, true)
            XCTAssertNil(pane.loadingTimeoutError)
        }
    }

    @MainActor
    func testMailboxDomainTextUpdateDisarmsTimeoutDespiteStalledImage() async throws {
        try await withStalledImage(host: "fviainboxes.com", body: """
        <input id="username"><button id="headlessui-listbox-button-1">nodomain</button><button>Get Email</button>
        """) { pane in
            var state = await pane.snapshot()
            XCTAssertEqual(state["mailReady"] as? Bool, false)
            XCTAssertTrue(pane.loading)
            _ = try await pane.webView.evaluateJavaScript("document.querySelector('[id^=headlessui-listbox-button]').firstChild.nodeValue = 'fviainboxes.com'")
            state = await pane.snapshot()
            XCTAssertEqual(state["mailReady"] as? Bool, true)
            try await self.waitUntil { !pane.loading }
            XCTAssertNil(pane.loadingTimeoutError)
        }
    }

    @MainActor
    func testContinuousLoadingTimesOutAndStopsLoading() async throws {
        XCTAssertEqual(PageLoadTimeout.defaultSeconds, 10)
        let pane = BrowserPane(host: "api.jiucaihezi.studio", loadingTimeout: 0.02)
        pane.webView(pane.webView, didStartProvisionalNavigation: nil)
        XCTAssertTrue(pane.loading)
        try await waitUntil { pane.loadingTimeoutError != nil }
        XCTAssertFalse(pane.loading)
        XCTAssertEqual(pane.loadingTimeoutError?.seconds, 0.02)
        XCTAssertTrue(pane.navigationError?.contains("0.02 秒") == true)
    }

    @MainActor
    func testCustomLoadingTimeoutControlsDeadline() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio", loadingTimeout: 0.15)
        pane.webView(pane.webView, didStartProvisionalNavigation: nil)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(pane.loadingTimeoutError)
        try await waitUntil { pane.loadingTimeoutError != nil }
        XCTAssertEqual(pane.loadingTimeoutError?.seconds, 0.15)
    }

    @MainActor
    func testCancelledOldNavigationCannotDisableCurrentDeadline() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio", loadingTimeout: 0.02)
        pane.webView(pane.webView, didStartProvisionalNavigation: nil)
        pane.webView(pane.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        try await waitUntil { pane.loadingTimeoutError != nil }
        XCTAssertEqual(pane.loadingTimeoutError?.seconds, 0.02)
    }

    @MainActor
    func testNativeWebKitTimeoutUsesSameDiscardableError() {
        let pane = BrowserPane(host: "api.jiucaihezi.studio", loadingTimeout: 17)
        pane.webView(pane.webView, didStartProvisionalNavigation: nil)
        pane.webView(pane.webView, didFailProvisionalNavigation: nil, withError: URLError(.timedOut))
        XCTAssertEqual(pane.loadingTimeoutError?.seconds, 17)
        XCTAssertFalse(pane.loading)
    }

    @MainActor
    func testCertificateFailureExplainsCauseWithoutCopyingSensitiveErrorDetails() {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                            userInfo: [NSLocalizedDescriptionKey: "private-password",
                                       NSURLErrorFailingURLStringErrorKey: "https://private-user:private-password@private.invalid/?token=private-token"])
        pane.webView(pane.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertTrue(pane.navigationError?.contains("证书") == true)
        XCTAssertTrue(pane.navigationError?.contains("-1202") == true)
        XCTAssertFalse(pane.navigationError?.contains("private-") == true)
    }

    @MainActor
    func testReloadIgnoresFailureFromPreviousNavigationInSameWebView() throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        let source = WKWebView()
        let previous = try XCTUnwrap(source.loadHTMLString("<html>previous</html>", baseURL: nil))
        let current = try XCTUnwrap(source.loadHTMLString("<html>current</html>", baseURL: nil))
        pane.webView(pane.webView, didStartProvisionalNavigation: previous)
        pane.webView(pane.webView, didStartProvisionalNavigation: current)
        pane.webView(pane.webView, didFailProvisionalNavigation: previous, withError: URLError(.networkConnectionLost))
        XCTAssertNil(pane.navigationError, "A late error from the previous load must not fail a good proxy")
        XCTAssertTrue(pane.loading)
        pane.stopLoading()
        source.stopLoading()
    }

    @MainActor
    func testReloadIgnoresCompletionFromPreviousNavigationInSameWebView() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio", loadingTimeout: 0.02)
        let source = WKWebView()
        let previous = try XCTUnwrap(source.loadHTMLString("<html>previous</html>", baseURL: nil))
        let current = try XCTUnwrap(source.loadHTMLString("<html>current</html>", baseURL: nil))
        pane.webView(pane.webView, didStartProvisionalNavigation: previous)
        pane.webView(pane.webView, didStartProvisionalNavigation: current)
        pane.webView(pane.webView, didFinish: previous)
        XCTAssertTrue(pane.loading, "A late completion must not cancel the current loading deadline")
        try await waitUntil { pane.loadingTimeoutError != nil }
        XCTAssertNotNil(pane.loadingTimeoutError)
        source.stopLoading()
    }

    @MainActor
    func testStoppedNavigationCannotRestartLoading() throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        let source = WKWebView()
        let navigation = try XCTUnwrap(source.loadHTMLString("<html>current</html>", baseURL: nil))
        pane.webView(pane.webView, didStartProvisionalNavigation: navigation)
        pane.stopLoading()
        pane.webView(pane.webView, didStartProvisionalNavigation: navigation)
        XCTAssertFalse(pane.loading)
        pane.stopLoading()
        source.stopLoading()
    }

    @MainActor
    func testFinishedPageDoesNotTimeoutWhileWaitingForEmailOrUserInput() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio", loadingTimeout: 0.02)
        pane.webView(pane.webView, didStartProvisionalNavigation: nil)
        pane.webView(pane.webView, didFinish: nil)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(pane.loading)
        XCTAssertNil(pane.loadingTimeoutError)
        XCTAssertNil(pane.navigationError)
    }

    @MainActor
    func testReplacingOrStoppingPageCancelsOldLoadingTimeout() async throws {
        for rebuild in [false, true] {
            let pane = BrowserPane(host: "api.jiucaihezi.studio", loadingTimeout: 0.02)
            let old = pane.webView
            pane.webView(old, didStartProvisionalNavigation: nil)
            if rebuild { pane.rebuildWebView() } else { pane.stopLoading() }
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertFalse(pane.loading)
            XCTAssertNil(pane.loadingTimeoutError)
            XCTAssertNil(pane.navigationError)
            if rebuild {
                pane.webView(old, didStartProvisionalNavigation: nil)
                XCTAssertFalse(pane.loading, "Discarded views cannot restart the timer")
            }
        }
    }

    @MainActor
    func testTimeoutDiscardsProxyAndContinuesWithItsImmediateSuccessor() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio", loadingTimeout: 0.02)
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        configuration.entries = (0..<4).map { ProxyEntry(host: "loading\($0).invalid", port: 1080) }
        let original = configuration.entries
        var nextProxy: UUID?
        var attempted: [UUID] = []
        try await RegistrationRetry.run(selectProxy: { previous, excluded in
            let selection = try ProxyManager.selectProxy(configuration: configuration, completedCount: 1,
                                                         startingAfter: previous, startingAt: nextProxy,
                                                         excluding: excluded)
            nextProxy = nil
            return selection
        }, attempt: { proxy in
            let entry = try XCTUnwrap(proxy)
            attempted.append(entry.id)
            if attempted.count == 1 {
                pane.webView(pane.webView, didStartProvisionalNavigation: nil)
                try await self.waitUntil { pane.loadingTimeoutError != nil }
                throw try XCTUnwrap(pane.loadingTimeoutError)
            }
        }, shouldRetry: { true }, onRetry: { entry, error in
            XCTAssertTrue(error is PageLoadTimeout)
            nextProxy = ProxyManager.discardFailedProxy(entry, configuration: &configuration)
        })
        XCTAssertEqual(attempted, [original[1].id, original[2].id])
        XCTAssertEqual(configuration.entries, [original[0], original[2], original[3]])
    }
}

@MainActor
private final class HeldResourceConnections {
    var values: [NWConnection] = []
}
