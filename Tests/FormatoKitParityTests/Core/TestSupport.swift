import Foundation
import FormatoKitTestSupport

/// Paths of the fixtures and of the pinned RosettaSciIO clone (gitignored; absent in a clone without References).
enum TestPaths {
    static let fixtures = FixtureDirs.fixtures(of: "FormatoCoreTests")
    static let root = FixtureDirs.repository
    static let rsciioData = root.appendingPathComponent("References/rosettasciio-049e7d70/rsciio/tests/data")
    /// The public zips' members, unzipped by tools/test.sh after their sha256 is checked against the registry.
    static let unzipped = root.appendingPathComponent(".build/rsciio-unzipped")
}

func bits(_ hex: String) -> Double { Double(bitPattern: UInt64(hex, radix: 16)!) }
func hex(_ d: Double) -> String { String(format: "%016llx", d.bitPattern) }

func loadJSON(_ name: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: TestPaths.fixtures.appendingPathComponent(name))) as! [String: Any]
}
