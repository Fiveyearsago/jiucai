import XCTest
import WebKit
import RegistrationCore
@testable import BeautyRegistration

final class BrowserIntegrationTests: XCTestCase {
    @MainActor
    func testHeaderChoicesAndSafeObservationsInRealWebKit() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        let configuration = RequestHeaderConfiguration(mode: .webKit, language: .chinese, accept: .general)
        pane.loadFixture("""
        <html><body><input name="username"><input name="confirmPassword"><script>
        window.fixtureSend = () => {
          const xhr = new XMLHttpRequest(); xhr.open('POST', '/api/user/register?email=fixture@test.invalid&token=private-query');
          xhr.setRequestHeader('Accept', 'text/plain');
          xhr.setRequestHeader('Content-Type', 'application/json');
          xhr.setRequestHeader('Cache-Control', 'no-cache');
          xhr.setRequestHeader('Authorization', 'Bearer private-token');
          xhr.send('private-body');
        };
        </script></body></html>
        """, baseURL: URL(string: "https://api.jiucaihezi.studio/sign-up")!, headers: configuration,
        prelude: "XMLHttpRequest.prototype.send = function() {}; // Local fixture: never contacts the server.\n")
        for _ in 0..<100 {
            if await pane.snapshot()["regReady"] as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await pane.webView.evaluateJavaScript("fixtureSend()")
        for _ in 0..<100 {
            if pane.requestObservations.first?.transport == "XMLHttpRequest" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let observed = try XCTUnwrap(pane.requestObservations.first)
        XCTAssertEqual(observed.path, "/api/user/register")
        XCTAssertEqual(observed.method, "POST")
        XCTAssertEqual(pane.appliedHeaders, configuration)
        let headers = Dictionary(uniqueKeysWithValues: observed.headers.map { ($0.name, $0.value) })
        XCTAssertEqual(headers["Accept"], configuration.accept.value)
        XCTAssertEqual(headers["Accept-Language"], configuration.language.value)
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["Cache-Control"], "no-cache")
        XCTAssertNil(headers["Authorization"])
        XCTAssertFalse(observed.headers.contains { $0.value.contains("private-") })
        _ = try await pane.webView.evaluateJavaScript("for (let i=0;i<25;i++) fixtureSend()")
        for _ in 0..<100 {
            if pane.requestObservations.count == 20 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(pane.requestObservations.count, 20)
    }

    @MainActor
    func testVerificationRateLimitWaitsAndReceivesFreshReplyInRealWebKit() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        pane.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        pane.loadFixture("""
        <html><body><input name="username"><input name="confirmPassword">
        <button onclick="sendFixture()">发送验证码</button><script>
        window.sendTimes = [];
        function sendFixture() {
          sendTimes.push(performance.now());
          const rejected = sendTimes.length === 1;
          const xhr = new XMLHttpRequest(); xhr.open('GET', '/api/verification');
          Object.defineProperty(xhr, 'status', {value: rejected ? 429 : 200});
          Object.defineProperty(xhr, 'responseText', {value: JSON.stringify({success: !rejected, message: rejected ? '发送过于频繁，请等待 1 秒后再试' : ''})});
          xhr.getResponseHeader = name => name.toLowerCase() === 'retry-after' && rejected ? '1' : null;
          xhr.dispatchEvent(new Event('load'));
        }
        </script></body></html>
        """, baseURL: URL(string: "https://api.jiucaihezi.studio/sign-up")!)
        for _ in 0..<100 {
            if await pane.snapshot()["regReady"] as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        var waits = 0
        try await VerificationRetry.send(attempt: {
            pane.verification = nil
            let clicked = try await pane.call("sendCode") as? String
            XCTAssertEqual(clicked, "clicked")
            for _ in 0..<100 {
                if let response = pane.verification { return response }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw ClientError.message("Fixture did not return a reply")
        }, wait: { seconds, retry in
            waits += 1
            XCTAssertEqual(seconds, 5)
            XCTAssertEqual(retry, 1)
            XCTAssertEqual(pane.verification?["retryAfterSeconds"] as? Int, 1)
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        })
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(pane.verification?["success"] as? Bool, true)
        let times = try await pane.webView.evaluateJavaScript("sendTimes") as? [Double]
        XCTAssertEqual(times?.count, 2)
        if let times, times.count == 2 { XCTAssertGreaterThanOrEqual(times[1] - times[0], 5000) }
        XCTAssertNil(pane.registration, "Retrying verification must not submit registration")
    }

    @MainActor
    func testSafariCompatibilityProfileUsesBrowserUserAgentWithoutChangingMailbox() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        pane.loadFixture("<html><body>Header fixture</body></html>",
                         baseURL: URL(string: "https://api.jiucaihezi.studio/sign-up")!, compatibilityHeaders: true)
        var profile = ""
        for _ in 0..<100 {
            profile = await pane.snapshot()["requestProfile"] as? String ?? ""
            if !profile.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(profile, "Safari 兼容")
        let agent = try await pane.webView.evaluateJavaScript("navigator.userAgent") as? String
        await pane.refreshUserAgent()
        XCTAssertEqual(pane.appliedHeaderMode, .safari)
        XCTAssertEqual(pane.currentUserAgent, agent)
        XCTAssertEqual(pane.appliedHeaders?.accept.value, "application/json")
        XCTAssertEqual(pane.appliedHeaders?.language.value, "en-US,en;q=0.9")
        XCTAssertTrue(agent?.contains("Version/") == true)
        XCTAssertTrue(agent?.contains("Safari/605.1.15") == true)
        let mailbox = BrowserPane(host: "fviainboxes.com")
        mailbox.loadFixture("<html><body>Mailbox fixture</body></html>",
                            baseURL: URL(string: "https://fviainboxes.com")!, compatibilityHeaders: true)
        for _ in 0..<100 {
            if await mailbox.snapshot()["documentID"] != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let mailboxAgent = try await mailbox.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        XCTAssertTrue(mailboxAgent.contains("AppleWebKit/"))
        XCTAssertFalse(mailboxAgent.contains("Version/"))
        pane.loadFixture("<html><body>Default header fixture</body></html>",
                         baseURL: URL(string: "https://api.jiucaihezi.studio/sign-up")!)
        for _ in 0..<100 {
            if await pane.snapshot()["requestProfile"] as? String == "默认 WebKit" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let restoredAgent = try await pane.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        XCTAssertFalse(restoredAgent.contains("Version/"))
        await pane.refreshUserAgent()
        XCTAssertEqual(pane.appliedHeaderMode, .webKit)
        XCTAssertEqual(pane.currentUserAgent, restoredAgent)
        XCTAssertNil(pane.appliedHeaders?.accept.value)
        XCTAssertNil(pane.appliedHeaders?.language.value)
    }

    @MainActor
    func testRealWebKitPollingWaitsThenRetriesEmptyInboxAndStopsAtCode() async throws {
        let pane = BrowserPane(host: "fviainboxes.com")
        pane.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        pane.loadFixture("""
        <html><body><input id="username">
        <button id="headlessui-listbox-button-3">fviainboxes.com</button>
        <button onclick="getEmail()">Get Email</button><main><ul></ul></main>
        <script>
        window.mailClicks = [];
        function respond(path, body) {
          const xhr = new XMLHttpRequest(); xhr.open('GET', path);
          Object.defineProperty(xhr, 'status', {value: 200});
          Object.defineProperty(xhr, 'responseText', {value: typeof body === 'string' ? body : JSON.stringify(body)});
          xhr.dispatchEvent(new Event('load'));
        }
        function getEmail() {
          mailClicks.push(performance.now());
          let result = [];
          if (mailClicks.length >= 3) {
            result = [{id: 'fixture-message', subject: '韭菜盒子邮箱验证邮件', from: 'jiucaihezi', createdAt: Math.floor(Date.now()/1000)}];
            document.querySelector('main ul').innerHTML = '<li onclick="openMessage()">韭菜盒子邮箱验证邮件</li>';
          }
          respond('/messages?username=fixture204&domain=fviainboxes.com', {result});
        }
        function openMessage() {
          setTimeout(() => respond('/message?username=fixture204&domain=fviainboxes.com&id=fixture-message',
            '<p>您的验证码为：<b>a7F91c</b></p>'), 50);
        }
        </script></body></html>
        """, baseURL: URL(string: "https://fviainboxes.com")!)
        for _ in 0..<100 {
            if await pane.snapshot()["mailReady"] as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await pane.call("prepareMailbox", arguments: ["username":"fixture204"])
        _ = try await pane.call("armMailbox")
        let before = try await pane.webView.evaluateJavaScript("mailClicks.length") as? Int
        XCTAssertEqual(before, 0)
        _ = try await pane.webView.evaluateJavaScript("window.confirmedAt = performance.now()")
        _ = try await pane.call("beginMailboxPolling")
        let immediate = try await pane.call("pollMailbox") as? String
        XCTAssertEqual(immediate, "waiting")
        var received = false
        for _ in 0..<160 {
            _ = try await pane.call("pollMailbox")
            if await pane.snapshot()["code"] as? String == "a7F91c" { received = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(received, "The third inbox response should produce an automatically read code")
        let completed = try await pane.call("pollMailbox") as? String
        XCTAssertEqual(completed, "complete")
        let timing = try await pane.webView.evaluateJavaScript("[mailClicks[0]-confirmedAt, mailClicks[1]-mailClicks[0], mailClicks[2]-mailClicks[1], mailClicks.length]") as? [Double]
        let times = try XCTUnwrap(timing)
        XCTAssertEqual(times.count, 4)
        XCTAssertEqual(times[3], 3)
        for interval in times.prefix(3) { XCTAssertGreaterThanOrEqual(interval, 2000) }
    }

    @MainActor
    func testMailboxWaitsForAsyncDomainAndCanPrepareAfterItLoads() async throws {
        let pane = BrowserPane(host: "fviainboxes.com")
        pane.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        pane.loadFixture("""
        <html><body>
        <input id="username">
        <button id="headlessui-listbox-button-3"></button>
        <button id="get-email" onclick="window.mailClicks=(window.mailClicks||0)+1">Get Email</button>
        </body></html>
        """, baseURL: URL(string: "https://fviainboxes.com")!)
        var state: [String: Any] = [:]
        for _ in 0..<100 {
            state = await pane.snapshot()
            if state["documentID"] != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(state["mailReady"] as? Bool, false, "An empty async domain selector is not a ready mailbox")
        let pending = try await pane.call("prepareMailbox", arguments: ["username":"fixture301"]) as? String
        XCTAssertEqual(pending, "waiting")
        let unchanged = try await pane.webView.evaluateJavaScript("document.querySelector('#username').value === '' && !window.mailClicks") as? Bool
        XCTAssertEqual(unchanged, true)
        _ = try await pane.webView.evaluateJavaScript("document.querySelector('#headlessui-listbox-button-3').textContent = 'fviainboxes.com'")
        let ready = await pane.snapshot()
        XCTAssertEqual(ready["mailReady"] as? Bool, true)
        let prepared = try await pane.call("prepareMailbox", arguments: ["username":"fixture301"]) as? String
        XCTAssertEqual(prepared, "prepared")
        let result = try await pane.webView.evaluateJavaScript("document.querySelector('#username').value === 'fixture301' && !window.mailClicks") as? Bool
        XCTAssertEqual(result, true)
    }

    @MainActor
    func testReloadNeverReturnsReadyStateFromPreviousDocument() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        pane.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let html = "<html><body><input name='username'><input name='confirmPassword'></body></html>"
        let url = URL(string: "https://api.jiucaihezi.studio/sign-up")!
        pane.loadFixture(html, baseURL: url)
        var first: [String: Any] = [:]
        for _ in 0..<100 {
            first = await pane.snapshot()
            if first["regReady"] as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let previousID = try XCTUnwrap(first["documentID"] as? String)
        pane.loadFixture(html, baseURL: url)
        var ready = false
        for _ in 0..<100 {
            let state = await pane.snapshot()
            if state["regReady"] as? Bool == true {
                XCTAssertNotEqual(state["documentID"] as? String, previousID)
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready)
    }

    @MainActor
    func testMailboxAdsCollapseWithoutHidingEmailOrVerification() async throws {
        let pane = BrowserPane(host: "fviainboxes.com")
        pane.webView.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
        pane.loadFixture("""
        <!doctype html><html><body style="padding-bottom:140px">
        <div class="max-w-[110rem]" id="layout" style="min-height:2000px">
          <aside id="left"><div>Sponsored</div><div class="ad-slot" style="height:600px">Ad</div></aside>
          <aside data-right-rail id="right"><div>Sponsored</div><div class="ad-slot">Ad</div></aside>
          <div data-top-strip id="top"><div>Sponsored</div><div class="ad-slot" style="height:120px">Ad</div></div>
          <div class="midad-rails" id="middle">Sponsored<div class="ad-slot">Ad</div></div>
          <div class="my-5" id="card"><div>Sponsored</div><div><div class="ad-slot">Ad</div></div></div>
          <input id="username"><button id="headlessui-listbox-button-3">fviainboxes.com</button><button>Get Email</button><a id="terms" href="/terms">Terms of Service</a>
          <div id="verification"><iframe title="Cloudflare verification" srcdoc="Verification"></iframe></div>
          <main id="inbox"><ul><li>Verification email</li></ul>
            <section><div class="ad-slot" id="pane-ad" style="height:280px">Ad</div>
              <iframe title="Email content" id="email" srcdoc="Your verification code is 123456"></iframe>
            </section>
          </main>
          <div class="fixed" id="floating"><button aria-label="Close ad">Close</button><iframe title="Advertisement" srcdoc="Ad"></iframe></div>
        </div></body></html>
        """, baseURL: URL(string: "https://fviainboxes.com")!)
        var ready = false
        for _ in 0..<100 {
            if await pane.snapshot()["mailReady"] as? Bool == true { ready = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(ready)
        guard ready else { return }
        let checks = try await pane.webView.evaluateJavaScript("""
        (() => {
          const hidden = id => document.getElementById(id).getBoundingClientRect().height === 0;
          const kept = id => document.getElementById(id).getBoundingClientRect().height > 0;
          const late = document.createElement('div'); late.className = 'ad-slot'; late.id = 'late';
          late.style.height = '120px'; late.textContent = 'Later ad'; document.body.appendChild(late);
          return {
            adsHidden: ['left','right','top','middle','card','pane-ad','floating','late'].every(hidden),
            mailPreserved: ['username','terms','verification','inbox','email'].every(kept),
            noBottomGap: getComputedStyle(document.body).paddingBottom === '0px',
            noReservedHeight: getComputedStyle(document.getElementById('layout')).minHeight === '0px'
          };
        })()
        """) as? [String: Bool]
        XCTAssertEqual(checks, ["adsHidden": true, "mailPreserved": true, "noBottomGap": true, "noReservedHeight": true])
    }

    @MainActor
    func testBridgeFillsRealWebKitFormAndEmitsOnlyMatchingResponses() async throws {
        let pane = BrowserPane(host: "api.jiucaihezi.studio")
        pane.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let html = """
        <!doctype html><html><body><form>
        <input name="username"><input type="password" name="password"><input type="password" name="confirmPassword">
        <input name="email" type="email"><input placeholder="验证码">
        <button type="button">发送验证码</button><button type="submit" disabled>创建账户</button>
        </form></body></html>
        """
        pane.loadFixture(html, baseURL: URL(string: "https://api.jiucaihezi.studio/sign-up")!)
        var ready = false
        for _ in 0..<100 {
            if await pane.snapshot()["regReady"] as? Bool == true { ready = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(ready, "Bridge did not initialize in WKWebView")
        guard ready else { return }
        let hasMailboxCSS = try await pane.webView.evaluateJavaScript("!!document.getElementById('beauty-mailbox-cleanup')") as? Bool
        XCTAssertEqual(hasMailboxCSS, false)
        let value = try await pane.call("fillRegistration", arguments: ["username":"fixture176", "email":"fixture176@test.invalid", "password":"fixture-only-password"]) as? [String: Any]
        XCTAssertEqual(value?["requiresEmail"] as? Bool, true)
        let filled = try await pane.webView.evaluateJavaScript("JSON.stringify(Array.from(document.querySelectorAll('input[name]')).map(e=>e.value))") as? String
        XCTAssertEqual(filled, "[\"fixture176\",\"fixture-only-password\",\"fixture-only-password\",\"fixture176@test.invalid\"]")
        _ = try await pane.call("fillCode", arguments: ["code":"a7F91c"])
        let code = try await pane.webView.evaluateJavaScript("document.querySelector('input[placeholder]').value") as? String
        XCTAssertEqual(code, "a7F91c")
        let submit = try await pane.call("submit") as? String
        XCTAssertEqual(submit, "disabled")
        // Dispatch a local synthetic XHR completion: no request is sent to the external service.
        _ = try await pane.webView.evaluateJavaScript("""
        (() => {
          const xhr = new XMLHttpRequest(); xhr.open('POST', '/api/user/register');
          Object.defineProperty(xhr, 'status', {value:200});
          Object.defineProperty(xhr, 'responseText', {value:'{"success":true,"secret":"must-not-cross-bridge"}'});
          xhr.dispatchEvent(new Event('load')); return true;
        })()
        """)
        for _ in 0..<30 {
            if pane.registration != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(pane.registration?["success"] as? Bool, true)
        XCTAssertNil(pane.registration?["secret"])
    }
}
