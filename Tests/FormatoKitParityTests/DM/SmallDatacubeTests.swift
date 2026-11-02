//
//  SmallDatacubeTests.swift
//  py4DSTEM's public test file `small_datacube.dm4` (210 MB): object 2 is a rank-3 stack (400, 512, 512) of uint16 with
//  "4D STEM Tags.Scan shape X/Y" = 20, read by py4DSTEM as the 20 x 20 x 512 x 512 cube. `DM4Datacube` reads it so, the
//  frames equal the stored stack's (`DMFile.signal`, RosettaSciIO's array) byte for byte. A real-data check: it shows as
//  skipped when the folder of py4DSTEM's test data ($PY4DSTEM_TEST_DATA, else References/py4dstem-test-data) lacks the file.
//

import Foundation
import Testing
import FormatoCore
import FormatoDM
import FormatoKitTestSupport

@Suite struct SmallDatacubeTests {
    private static let path: String = {
        let folder = ProcessInfo.processInfo.environment["PY4DSTEM_TEST_DATA"]
            ?? FixtureDirs.repository.appendingPathComponent("References/py4dstem-test-data").path
        return URL(fileURLWithPath: folder).appendingPathComponent("small_datacube.dm4").path
    }()

    @Test(.enabled(if: FileManager.default.fileExists(atPath: path), "small_datacube.dm4 is not in the py4DSTEM test data folder"))
    func theRank3StackReadsAsTwentyByTwentyScan() throws {
        let stack = try DMFile(path: Self.path).signal(index: 2)
        #expect(stack.array.shape == [400, 512, 512])
        for convention in [DM4GatherConvention.rosettaSciIO, .appCalibratedAxes] {
            let cube = try DM4Datacube(path: Self.path, convention: convention)
            #expect(cube.object.index == 2)
            #expect(cube.signal.array.shape == [20, 20, 512, 512])
            #expect(cube.layout.storedType == .uint16 && !cube.layout.scanFastest)
            for (y, x) in [(0, 0), (0, 19), (7, 3), (19, 19)] {
                let frame = try cube.frame(scanY: y, scanX: x)
                let stored = try stack.array.read(start: [y * 20 + x, 0, 0], count: [1, 512, 512])
                if convention == .rosettaSciIO {
                    #expect(frame.bytes == stored.bytes, "frame (\(y), \(x))")
                } else {
                    #expect(frame.doubles() == stored.doubles(), "frame (\(y), \(x))")
                }
            }
        }
    }
}
