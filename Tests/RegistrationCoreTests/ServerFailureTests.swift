import XCTest
@testable import RegistrationCore

final class ServerFailureTests: XCTestCase {
    func testShowsBusinessFailureAndStatusInsteadOfGenericRejection() {
        XCTAssertEqual(ServerFailure.describe(["status": 200, "message": "验证码错误或已过期"], operation: "注册"),
                       "注册失败（HTTP 200）：验证码错误或已过期")
    }
    func testEmptyResponsesExplainTransportFailure() {
        XCTAssertTrue(ServerFailure.describe(["status": 429], operation: "发送验证码").contains("请求频率"))
        XCTAssertTrue(ServerFailure.describe(["status": 403], operation: "注册").contains("网站拒绝访问"))
        XCTAssertTrue(ServerFailure.describe(["status": 502], operation: "注册").contains("网站服务异常"))
        XCTAssertTrue(ServerFailure.describe(nil, operation: "注册").contains("未提供具体错误说明"))
    }
}
