import Foundation
import XCTest
@testable import RegistrationCore

final class MailVerificationTests: XCTestCase {
    func testParsesMessageMetadataWithStringAndNumericIDs() throws {
        let data = Data("""
        {"result":[
          {"id":"mail-1","subject":"[New API] 邮箱验证码","from":"New API <noreply@jiucaihezi.studio>","createdAt":1700000000},
          {"id":42,"subject":"Jiucai verification code","from":"noreply@example.com","createdAt":1700000001}
        ]}
        """.utf8)

        XCTAssertEqual(try MailVerification.messages(from: data), [
            MailboxMessage(id: "mail-1", subject: "[New API] 邮箱验证码",
                           sender: "New API <noreply@jiucaihezi.studio>", createdAt: 1_700_000_000),
            MailboxMessage(id: "42", subject: "Jiucai verification code",
                           sender: "noreply@example.com", createdAt: 1_700_000_001)
        ])
    }

    func testNormalizesSecondsMillisecondsAndISO8601Timestamps() throws {
        let data = Data("""
        {"result":[
          {"id":"seconds","subject":"验证码","from":"jiucai","createdAt":"1700000000.25"},
          {"id":"milliseconds","subject":"验证码","from":"jiucai","createdAt":1700000000250},
          {"id":"string-milliseconds","subject":"验证码","from":"jiucai","createdAt":"1700000000250"},
          {"id":"iso","subject":"验证码","from":"jiucai","createdAt":"2023-11-14T22:13:20Z"},
          {"id":"iso-fraction","subject":"验证码","from":"jiucai","createdAt":"2023-11-15T06:13:20.250+08:00"}
        ]}
        """.utf8)

        let messages = try MailVerification.messages(from: data)
        XCTAssertEqual(messages.map(\.id), ["seconds", "milliseconds", "string-milliseconds", "iso", "iso-fraction"])
        for (message, timestamp) in zip(messages, [1_700_000_000.25, 1_700_000_000.25, 1_700_000_000.25,
                                                  1_700_000_000, 1_700_000_000.25]) {
            XCTAssertEqual(message.createdAt, timestamp, accuracy: 0.001)
        }
    }

    func testSkipsMissingMalformedAndNonfiniteTimestamps() throws {
        let data = Data("""
        {"result":[
          {"id":"missing","subject":"验证码","from":"jiucai"},
          {"id":"null","subject":"验证码","from":"jiucai","createdAt":null},
          {"id":"text","subject":"验证码","from":"jiucai","createdAt":"yesterday"},
          {"id":"nan","subject":"验证码","from":"jiucai","createdAt":"NaN"},
          {"id":"infinity","subject":"验证码","from":"jiucai","createdAt":"Infinity"},
          {"id":"boolean","subject":"验证码","from":"jiucai","createdAt":true},
          {"id":"object","subject":"验证码","from":"jiucai","createdAt":{}},
          {"id":"valid","subject":"验证码","from":"jiucai","createdAt":1700000000}
        ]}
        """.utf8)

        XCTAssertEqual(try MailVerification.messages(from: data).map(\.id), ["valid"])
    }

    func testSkipsRowsWithoutWellFormedMetadata() throws {
        let data = Data("""
        {"result":[
          null,
          "not a message",
          {"subject":"验证码","from":"jiucai","createdAt":1700000000},
          {"id":true,"subject":"验证码","from":"jiucai","createdAt":1700000000},
          {"id":"","subject":"验证码","from":"jiucai","createdAt":1700000000},
          {"id":"no-subject","from":"jiucai","createdAt":1700000000},
          {"id":"numeric-subject","subject":123,"from":"jiucai","createdAt":1700000000},
          {"id":"no-sender","subject":"验证码","createdAt":1700000000},
          {"id":"valid","subject":"验证码","from":"jiucai","createdAt":1700000000}
        ]}
        """.utf8)

        XCTAssertEqual(try MailVerification.messages(from: data).map(\.id), ["valid"])
        XCTAssertEqual(try MailVerification.messages(from: Data(#"{"result":[]}"#.utf8)), [])
    }

    func testMalformedMailboxResponsesUseOneFixedSafeClientError() {
        let payloads = [
            "private-mailbox@example.com secret-code",
            #"["private-mailbox@example.com"]"#,
            #"{"private-mailbox@example.com":"secret-code"}"#,
            #"{"result":null}"#,
            #"{"result":{"id":"secret-code"}}"#,
            #"{"result":"secret-code"}"#
        ]
        for payload in payloads {
            XCTAssertThrowsError(try MailVerification.messages(from: Data(payload.utf8))) { error in
                guard case let ClientError.message(message) = error else {
                    return XCTFail("Expected a safe ClientError for malformed mailbox data")
                }
                XCTAssertEqual(message, "邮箱服务返回了无法识别的邮件列表。")
            }
        }
    }

    func testCandidatesMatchChineseAndEnglishVerificationSubjectsNewestFirst() {
        let messages = [
            message("chinese", subject: "[New API] 邮箱验证码", sender: "noreply@example.com", time: 1_700_000_000),
            message("english", subject: "Verification code", sender: "JIUCAI <mail@example.com>", time: 1_700_000_001),
            message("tie-b", subject: "韭菜盒子邮件验证", sender: "noreply@example.com", time: 1_700_000_002),
            message("tie-a", subject: "New-API registration", sender: "noreply@example.com", time: 1_700_000_002),
            message("verify", subject: "Verify your email", sender: "New API", time: 1_700_000_003)
        ]

        XCTAssertEqual(MailVerification.candidates(in: messages, excluding: [], requestedAt: 1_700_000_000).map(\.id),
                       ["verify", "tie-a", "tie-b", "english", "chinese"])
    }

    func testCandidatesExcludeBaselineStaleUnrelatedAndUnknownDates() {
        let messages = [
            message("baseline", time: 1_700_000_005),
            message("old", time: 1_699_999_999.99),
            message("wrong-sender", subject: "邮箱验证", sender: "bank@example.com", time: 1_700_000_005),
            message("unrelated", subject: "Jiucai newsletter", time: 1_700_000_005),
            message("nan", time: .nan),
            message("infinity", time: .infinity),
            message("negative-infinity", time: -.infinity),
            message("current-second", time: 1_700_000_000)
        ]

        XCTAssertEqual(MailVerification.candidates(in: messages, excluding: ["baseline"], requestedAt: 1_700_000_000.9).map(\.id),
                       ["current-second"])
    }

    func testCandidatesRequireAKnownRequestTime() {
        for requestedAt in [TimeInterval.nan, .infinity, -.infinity] {
            XCTAssertEqual(MailVerification.candidates(in: [message("recent", time: 1_700_000_000)],
                                                      excluding: [], requestedAt: requestedAt), [])
        }
    }

    func testExtractsChineseCodeFromStyledHTMLWithoutChangingCase() {
        XCTAssertEqual(MailVerification.code(fromHTML: "<html><body><p>您的验证码为：<strong>aB3dE9</strong></p></body></html>"),
                       "aB3dE9")
        XCTAssertEqual(MailVerification.code(fromHTML: "<p>验证码：<span>A</span><b>b</b>12<span>C</span>3</p>"), "Ab12C3")
    }

    func testExtractsEnglishVerificationSecurityAndCodeIsMarkers() {
        XCTAssertEqual(MailVerification.code(fromHTML: "<p>Your verification code is: aZ09xY</p>"), "aZ09xY")
        XCTAssertEqual(MailVerification.code(fromHTML: "SECURITY CODE: Xy321z"), "Xy321z")
        XCTAssertEqual(MailVerification.code(fromHTML: "Your code is Qw4E6r."), "Qw4E6r")
    }

    func testDecodesNamedDecimalAndHexHTMLEntities() {
        XCTAssertEqual(MailVerification.code(fromHTML: "Verification&nbsp;code&#58;&nbsp;&#65;b&#x43;123"), "AbC123")
        XCTAssertEqual(MailVerification.code(fromHTML: "&#x9A8C;&#x8BC1;&#x7801;&#65306;&#49;&#50;AbCd"), "12AbCd")
    }

    func testIgnoresScriptsStylesCommentsAndTagAttributes() {
        let html = """
        <SCRIPT type="text/javascript">const text = 'Verification code: BAD123';</SCRIPT>
        <style>.example::after { content: '验证码：STY123'; }</style>
        <!-- Verification code: COM123 -->
        <p title="Security code: ATT123">Your verification code is <b>Good42</b>.</p>
        """

        XCTAssertEqual(MailVerification.code(fromHTML: html), "Good42")
        XCTAssertNil(MailVerification.code(fromHTML: "<script>验证码：BAD123</script><style>code is STY123</style><!-- code is COM123 -->"))
        XCTAssertNil(MailVerification.code(fromHTML: #"<span title="Verification code: ATT123">hello</span>"#))
    }

    func testRejectsUnanchoredOrLongerAlphanumericSequences() {
        for html in [
            "ABC123",
            "Your reference is ABC123",
            "Verification code: ABC1234",
            "Security code: XABC123",
            "验证码：ABC123xyz",
            "Verification code expired. Your reference is ABC123",
            "验证码：ＡＢＣ１２３"
        ] {
            XCTAssertNil(MailVerification.code(fromHTML: html))
        }
    }

    private func message(_ id: String, subject: String = "验证码", sender: String = "jiucai",
                         time: TimeInterval) -> MailboxMessage {
        MailboxMessage(id: id, subject: subject, sender: sender, createdAt: time)
    }
}
