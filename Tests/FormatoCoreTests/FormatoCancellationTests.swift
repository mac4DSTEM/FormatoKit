import XCTest
import FormatoCore

/// The renamed cancellation contract (registration §1.1): `check` throws exactly when the closure answers true.
final class FormatoCancellationTests: XCTestCase {
    func testCheckThrowsOnlyWhenCancelled() throws {
        XCTAssertNoThrow(try FormatoCancellation.check({ false }))
        XCTAssertThrowsError(try FormatoCancellation.check({ true })) { XCTAssertEqual($0 as? FormatoCancelled, FormatoCancelled()) }
    }

    func testDisplayFileNameIsTheLastComponent() {
        XCTAssertEqual(formatoDisplayFileName("/a/b/c.dm4"), "c.dm4")
        XCTAssertEqual(formatoDisplayFileName(""), "")
    }
}
