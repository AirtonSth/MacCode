import XCTest
@testable import SocketServer

final class ConnectionTelemetryRedactorTests: XCTestCase {
    func test_makeCorrelationId_returnsNonEmptyAndDistinctIds() {
        let first = ConnectionTelemetryRedactor.makeCorrelationId()
        let second = ConnectionTelemetryRedactor.makeCorrelationId()

        XCTAssertFalse(first.isEmpty, "correlation id must be non-empty")
        XCTAssertFalse(second.isEmpty, "correlation id must be non-empty")
        XCTAssertNotEqual(first, second, "successive correlation ids must differ")
    }
}
