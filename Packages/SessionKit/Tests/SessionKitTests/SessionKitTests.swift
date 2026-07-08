import XCTest
@testable import SessionKit

final class SessionKitTests: XCTestCase {
    func testPlaceholder() {
        let session = RecordedSession(startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(session.startedAt.timeIntervalSince1970, 0)
    }
}
