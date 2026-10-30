//
//  BigVeloxPeekTests.swift
//  A real-data check of Peek's memory bound, moved out of the fast unit target: it reads a local data file that a fresh
//  clone does not have, and shows as skipped without it. The data folder is $MACEM_DATA, else ../data beside the repository.
//

import Foundation
import Testing
import FormatoKitTestSupport
import FormatoPeek

@Suite struct BigVeloxPeekTests {
    private static let bigVelox: URL = {
        let dataRoot = ProcessInfo.processInfo.environment["MACEM_DATA"]
            ?? FixtureDirs.repository.deletingLastPathComponent().appendingPathComponent("data").path
        return URL(fileURLWithPath: dataRoot).appendingPathComponent("stem-edx/SI HAADF 1456 77000 x 20260420.emd")
    }()

    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Int(info.phys_footprint)
    }

    /// A 1.66 GB Velox spectrum image: a peek reads its HAADF image, not the cube.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: bigVelox.path), "the 1.66 GB Velox spectrum image is not in the data folder"))
    func theBigVeloxFileCostsUnderSixtyFourMegabytes() throws {
        let before = footprint()
        let frame = try Peek.thumbnailFrame(url: Self.bigVelox, maxPixels: 512)
        let after = footprint()
        #expect(frame.width <= 512 && frame.height <= 512 && frame.kind == .image)
        #expect(after - before < 64 << 20, "peek grew the footprint by \((after - before) >> 20) MB")
        _ = try Peek.summary(url: Self.bigVelox)
    }
}
