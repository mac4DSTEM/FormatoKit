import Foundation
// Identity view scaffolding only; the generator appends the pinned app reader unchanged.
enum VendorRawError: Error { case cannotOpen(String), malformed(String), unsupported(String), truncated(String) }
struct Crop { let xOffset: Int; let yOffset: Int; let width: Int; let height: Int }
struct LoadView {
    struct Descriptor { let ry = 1; let rx = 2 }
    let descriptor = Descriptor()
    var readDetectorCrop: Crop? { nil }
    func requireSource(shape: [Int]) throws { precondition(shape[0] == 1 && shape[1] == 2 && shape[2] == shape[3]) }
    func sourceScanY(_ y: Int) -> Int { y }
    func sourceScanX(_ x: Int) -> Int { x }
    func binned(_ values: [Float], patternCount: Int) -> [Float] { values }
}
enum EMPADReader {
    static func checkedProduct(_ values: [Int]) throws -> Int { values.reduce(1, *) }
    static func fileSize(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).intValue
    }
    static func read(path: String, offset: Int, count: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset)); return try file.read(upToCount: count)!
    }
}
