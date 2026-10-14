import Testing
import FormatoCore

/// The renamed cancellation contract (registration §1.1): `check` throws exactly when the closure answers true.
@Suite struct FormatoCancellationTests {
    @Test func testCheckThrowsOnlyWhenCancelled() throws {
        #expect(throws: Never.self) { try FormatoCancellation.check({ false }) }
        #expect(throws: FormatoCancelled()) { try FormatoCancellation.check({ true }) }
    }

    @Test func testDisplayFileNameIsTheLastComponent() {
        #expect(formatoDisplayFileName("/a/b/c.dm4") == "c.dm4")
        #expect(formatoDisplayFileName("") == "")
    }
}
