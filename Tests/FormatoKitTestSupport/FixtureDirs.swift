import Foundation

/// Where the committed fixtures live. They stay beside the test targets that first used them (tools/ generators and
/// Tests/Fixtures/README.md name those folders), so FormatoKitParityTests finds them here instead of through its own #filePath.
package enum FixtureDirs {
    /// The `Tests` folder, found from this file.
    package static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    /// The repository root.
    package static let repository = tests.deletingLastPathComponent()
    /// The public TIFF test data tools/test.sh unpacks from the pinned RosettaSciIO clone (absent when the tests run without it).
    package static let unpackedTIFF = repository.appendingPathComponent(".build/rsciio-tiff")
    /// `Tests/<target>/Fixtures`.
    package static func fixtures(of target: String) -> URL {
        tests.appendingPathComponent(target).appendingPathComponent("Fixtures")
    }
}
