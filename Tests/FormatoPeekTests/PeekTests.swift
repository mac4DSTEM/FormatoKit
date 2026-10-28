//
//  PeekTests.swift
//  Peek reads one decimated frame and the header facts. Its pixels are the file's own, point sampled, so the references are
//  (a) planted gradients written here (value = 1000 * row + column, closed form) and (b) the same file read whole by the
//  format's own reader and cut at the same stride; the dimensions, axes and acquisition fields are the readers' and are
//  compared with them. The rule, stated before the first run: stride = ceil(max(rows, cols) / maxPixels); output
//  ceil(rows / stride) x ceil(cols / stride); pixel (i, j) = source (i * stride, j * stride); a stack or cube is entered at
//  the centre index (size / 2) of every leading axis; a spectrum is binned to the largest value per bin.
//

import Testing
import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoHDF5
import FormatoKitTestSupport
import FormatoMRC
import FormatoMSA
import FormatoPeek
import FormatoTIFF

private let tests = FixtureDirs.tests
private func fixture(_ relative: String) -> URL { tests.appendingPathComponent(relative) }

/// The whole array cut the way Peek says it cuts: the centre of the leading axes, every `stride`-th row and column.
private func expectedPixels(_ array: any FormatoLazyArray, stride: Int) throws -> (width: Int, height: Int, pixels: [Float]) {
    let shape = array.shape
    let rows = shape[shape.count - 2], cols = shape[shape.count - 1]
    let lead = shape.dropLast(2).map { $0 / 2 }
    let plane = try array.read(start: lead + [0, 0], count: [Int](repeating: 1, count: lead.count) + [rows, cols]).doubles()
    let h = (rows + stride - 1) / stride, w = (cols + stride - 1) / stride
    var out = [Float](repeating: 0, count: h * w)
    for i in 0..<h { for j in 0..<w { out[i * w + j] = Float(plane[i * stride * cols + j * stride]) } }
    return (w, h, out)
}

private func check(_ frame: Peek.Frame, against array: any FormatoLazyArray, maxPixels: Int, kind: Peek.Kind = .image) throws {
    let shape = array.shape
    let rows = shape[shape.count - 2], cols = shape[shape.count - 1]
    let stride = max(1, (max(rows, cols) + maxPixels - 1) / maxPixels)
    let expected = try expectedPixels(array, stride: stride)
    #expect(frame.stride == stride)
    #expect(frame.width == expected.width && frame.height == expected.height)
    #expect(frame.sourceWidth == cols && frame.sourceHeight == rows)
    #expect(frame.pixels == expected.pixels)
    #expect(frame.kind == kind)
    #expect(frame.enteredAt == shape.dropLast(2).map { $0 / 2 })
}

/// A little-endian float32 MRC of `rows` x `cols` with value 1000 * row + column.
private func plantedMRC(rows: Int, cols: Int) -> Data {
    var header = Data(count: 1024)
    func put(_ v: Int32, at o: Int) { withUnsafeBytes(of: v.littleEndian) { header.replaceSubrange(o..<o + 4, with: $0) } }
    func putF(_ v: Float, at o: Int) { withUnsafeBytes(of: v.bitPattern.littleEndian) { header.replaceSubrange(o..<o + 4, with: $0) } }
    put(Int32(cols), at: 0); put(Int32(rows), at: 4); put(1, at: 8); put(2, at: 12)
    put(Int32(cols), at: 28); put(Int32(rows), at: 32); put(1, at: 36)
    putF(Float(cols), at: 40); putF(Float(rows), at: 44); putF(1, at: 48)
    var body = Data()
    for r in 0..<rows { for c in 0..<cols { withUnsafeBytes(of: Float(1000 * r + c).bitPattern.littleEndian) { body.append(contentsOf: $0) } } }
    return header + body
}

private func temporary(_ name: String, _ data: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

@Suite(.serialized) struct PeekTests {
    @Test func aPlantedGradientComesBackAtEveryStride() throws {
        let url = try temporary("gradient.mrc", plantedMRC(rows: 7, cols: 11))
        let full = try Peek.thumbnailFrame(url: url, maxPixels: 4096)
        #expect(full.stride == 1 && full.width == 11 && full.height == 7)
        for r in 0..<7 { for c in 0..<11 { #expect(full.pixels[r * 11 + c] == Float(1000 * r + c)) } }
        let coarse = try Peek.thumbnailFrame(url: url, maxPixels: 3)   // stride ceil(11 / 3) = 4 -> 2 rows, 3 columns
        #expect(coarse.stride == 4 && coarse.width == 3 && coarse.height == 2)
        #expect(coarse.pixels == [0, 4, 8, 4000, 4004, 4008])
        let s = try Peek.summary(url: url)
        #expect(s.format == "MRC" && s.width == 11 && s.height == 7)
        #expect(s.dataType == "float32")
    }

    @Test func aStackIsEnteredAtItsMiddleFrame() throws {
        let url = fixture("FormatoMRCTests/Fixtures/image-readers/stack-3.mrc")
        let array = try MRCReader(path: url.path).signal.array
        try check(try Peek.thumbnailFrame(url: url, maxPixels: 64), against: array, maxPixels: 64)
        try check(try Peek.thumbnailFrame(url: url, maxPixels: 1), against: array, maxPixels: 1)
        #expect(try Peek.thumbnailFrame(url: url, maxPixels: 64).enteredAt == [1])
    }

    @Test func tiffMatchesTheWholeReadAndKeepsItsCalibration() throws {
        let url = fixture("FormatoTIFFTests/Fixtures/planted/be-u16-3strips.tif")
        let tiff = try TIFFSignals(path: url.path)
        let signal = try tiff.signal(series: 0)
        try check(try Peek.thumbnailFrame(url: url, maxPixels: 64), against: signal.array, maxPixels: 64)
        try check(try Peek.thumbnailFrame(url: url, maxPixels: 2), against: signal.array, maxPixels: 2)
        let s = try Peek.summary(url: url)
        #expect(s.format == "TIFF" && s.width == signal.array.shape[1] && s.height == signal.array.shape[0])
        #expect(s.pixelSize == signal.axes.last?.scale && s.pixelUnit == signal.axes.last?.units)
    }

    @Test func digitalMicrographPicksAnImageAndNamesItsFields() throws {
        let url = fixture("FormatoDMTests/Fixtures/eels-planted.dm4")
        let dm = try DMFile(path: url.path)
        let frame = try Peek.thumbnailFrame(url: url, maxPixels: 64)
        let chosen = try #require(dm.objects.compactMap { try? dm.signal(index: $0.index) }.first { $0.array.shape.count == frame.enteredAt.count + 2 })
        try check(frame, against: chosen.array, maxPixels: 64)
        let s = try Peek.summary(url: url)
        #expect(s.format == "Gatan DigitalMicrograph" && s.title == "Planted survey", "the two-dimensional survey comes before the 3D cubes")
        #expect(s.width == chosen.array.shape.last && s.height == chosen.array.shape[chosen.array.shape.count - 2])
    }

    @Test func veloxPicksTheConsumersImageAndItsDetector() throws {
        let url = fixture("FormatoEMDTests/Fixtures/image-readers/velox-objects.emd")
        let images = try VeloxImageSignals(path: url.path)
        let entry = try #require(VeloxImageSelection.choose(images.images))
        let signal = try images.signal(entry)
        try check(try Peek.thumbnailFrame(url: url, maxPixels: 64), against: signal.array, maxPixels: 64)
        let s = try Peek.summary(url: url)
        #expect(s.format == "Velox EMD" && s.highTensionKV == 200)
        #expect(s.detector == AcquisitionMetadata.velox(entry).detector?.value)
    }

    @Test func aPy4DSTEMCubeGivesItsCentrePattern() throws {
        for (name, dataset) in [("float32", "/cube_root/cube/data"), ("uint16", "/cube_root/cube/data")] {
            let url = fixture("FormatoHDF5Tests/Fixtures/4d/\(name).h5")
            try #require(FileManager.default.fileExists(atPath: url.path), "fixture \(name).h5 is committed")
            let cube = try HDF5Datacube(path: url.path, datasetPath: dataset)
            let frame = try Peek.thumbnailFrame(url: url, maxPixels: 64)
            #expect(frame.kind == .diffractionPattern && frame.source == dataset)
            #expect(frame.enteredAt == [cube.shape[0] / 2, cube.shape[1] / 2])
            let centre = try cube.read(start: [cube.shape[0] / 2, cube.shape[1] / 2, 0, 0], count: [1, 1, cube.shape[2], cube.shape[3]]).doubles()
            #expect(frame.pixels == centre.map(Float.init))
            let coarse = try Peek.thumbnailFrame(url: url, maxPixels: 4)
            #expect(coarse.stride == (max(cube.shape[2], cube.shape[3]) + 3) / 4 && coarse.width == (cube.shape[3] + coarse.stride - 1) / coarse.stride)
            let s = try Peek.summary(url: url)
            #expect(s.scanHeight == cube.shape[0] && s.scanWidth == cube.shape[1] && s.height == cube.shape[2] && s.width == cube.shape[3])
            #expect(s.pixelSize == cube.axes[0].scale && s.detectorPixelUnit == cube.axes[2].units)
        }
    }

    @Test func aSpectrumIsBinnedToItsLargestValues() throws {
        let url = fixture("FormatoMSATests/Fixtures/public/ISO_22029_2022_compliance.msa")
        let spectrum = try MSAReader.read(path: url.path)
        let values = spectrum.signal.data.doubles()
        let frame = try Peek.thumbnailFrame(url: url, maxPixels: 4)
        #expect(frame.kind == .spectrum && frame.height == 1 && frame.sourceWidth == values.count)
        #expect(frame.width == min(4, values.count))
        #expect(frame.pixels.max() == Float(values.max() ?? 0), "a peak survives the binning")
        let whole = try Peek.thumbnailFrame(url: url, maxPixels: 4096)
        #expect(whole.pixels == values.map(Float.init))
    }

    /// A non-square 4D file written here: scan 3 x 5, detector 6 x 7, value = 100000 * scanRow + 10000 * scanColumn + 100 * qRow + qColumn,
    /// so a swapped width and height anywhere is a different number. A virtual image beside it (3 x 5, value 7 * row + column) wins.
    @Test func aNonSquareCubeKeepsItsFourDimensionsApartAndAStoredVirtualImageIsPreferred() throws {
        var values: [Float] = []
        for sr in 0..<3 { for sc in 0..<5 { for qr in 0..<6 { for qc in 0..<7 { values.append(Float(100000 * sr + 10000 * sc + 100 * qr + qc)) } } } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cube.h5")
        try EMDDatacubeWriter.write(values, layout: EMDDatacubeLayout(shape: [3, 5, 6, 7], header: EMDFileHeader(authoringProgram: "planted")), to: url)
        let plain = try Peek.summary(url: url)
        #expect(plain.scanHeight == 3 && plain.scanWidth == 5 && plain.height == 6 && plain.width == 7)
        let pattern = try Peek.thumbnailFrame(url: url, maxPixels: 64)   // centre position (1, 2)
        #expect(pattern.kind == .diffractionPattern && pattern.enteredAt == [1, 2] && pattern.width == 7 && pattern.height == 6)
        #expect(pattern.pixels[0] == 10000 * 2 + 100000 && pattern.pixels[6 * 7 - 1] == Float(100000 + 20000 + 500 + 6))
        var image: [Float] = []
        for r in 0..<3 { for c in 0..<5 { image.append(Float(7 * r + c)) } }
        try HDF5AppendWriter.append(to: url) { session in
            try session.createGroup("/datacube_root/virtual_images")
            try session.writeDataset("/datacube_root/virtual_images/virtual_haadf",
                                     FormatoArray(dataType: .float32, shape: [3, 5], bytes: image.withUnsafeBytes { Data($0) }))
        }
        let virtual = try Peek.thumbnailFrame(url: url, maxPixels: 64)
        #expect(virtual.kind == .virtualImage && virtual.width == 5 && virtual.height == 3 && virtual.pixels == image)
        let s = try Peek.summary(url: url)
        #expect(s.width == 5 && s.height == 3 && s.scanWidth == 5 && s.scanHeight == 3, "the card's size is the previewed frame's")
    }

    @Test func aSpectrumThatDoesNotDivideEvenlyKeepsEverySampleInABin() throws {
        let values = (0..<10).map { Double($0 == 6 ? 99 : $0) }
        let signal = FormatoSignal(title: "s", signalType: "EDS", axes: [FormatoAxis(name: "E", size: 10, scale: 1, offset: 0, units: "keV", navigate: false)],
                                   metadata: FormatoMetadata(), data: try FormatoArray(dataType: .float64, shape: [10], bytes: values.withUnsafeBytes { Data($0) }))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.msa")
        try MSAWriter.write(signal, to: url)
        let frame = try Peek.thumbnailFrame(url: url, maxPixels: 4)
        #expect(frame.width == 4 && frame.stride == 3 && frame.sourceWidth == 10)
        // sample i goes to bin i * 4 / 10: bins {0,1,2}, {3,4}, {5,6,7}, {8,9}; the 99 at sample 6 survives in bin 2.
        #expect(frame.pixels == [2, 4, 99, 9])
    }

    @Test func aTruncatedFileThrowsInsteadOfTrapping() throws {
        let url = try temporary("short.mrc", Data(count: 100))
        #expect(throws: (any Error).self) { try Peek.thumbnailFrame(url: url, maxPixels: 64) }
        #expect(throws: (any Error).self) { try Peek.summary(url: url) }
        let big = plantedMRC(rows: 7, cols: 11)
        let cut = try temporary("cut.mrc", big.prefix(1024 + 40))
        #expect(throws: (any Error).self) { try Peek.thumbnailFrame(url: cut, maxPixels: 64) }
    }

    @Test func theLimitIsHonouredAndNonsenseIsClamped() throws {
        let url = try temporary("gradient.mrc", plantedMRC(rows: 7, cols: 11))
        #expect(try Peek.thumbnailFrame(url: url, maxPixels: 0).width == 1)
        #expect(try Peek.thumbnailFrame(url: url, maxPixels: -5).width == 1)
        #expect(try Peek.thumbnailFrame(url: url, maxPixels: 100_000).width == 11)
    }

    @Test func refusalsNameTheFile() throws {
        let url = try temporary("nothing.xyz", Data([1, 2, 3]))
        #expect(throws: Peek.PeekError.self) { try Peek.thumbnailFrame(url: url, maxPixels: 64) }
        #expect(throws: Peek.PeekError.self) { try Peek.summary(url: url) }
        do { _ = try Peek.summary(url: url) } catch { #expect("\(error.localizedDescription)".contains("nothing.xyz")) }
    }

    /// The 1.66 GB Velox spectrum image of the study: a peek reads its HAADF image, not the cube. Skips without the data.
    @Test func theBigVeloxFileCostsUnderSixtyFourMegabytes() throws {
        let dataRoot = ProcessInfo.processInfo.environment["MACEM_DATA"] ?? FixtureDirs.repository.deletingLastPathComponent().appendingPathComponent("data").path
        let url = URL(fileURLWithPath: dataRoot).appendingPathComponent("stem-edx/SI HAADF 1456 77000 x 20260420.emd")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        func footprint() -> Int {
            var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return Int(info.phys_footprint)
        }
        let before = footprint()
        let frame = try Peek.thumbnailFrame(url: url, maxPixels: 512)
        let after = footprint()
        #expect(frame.width <= 512 && frame.height <= 512 && frame.kind == .image)
        #expect(after - before < 64 << 20, "peek grew the footprint by \((after - before) >> 20) MB")
        _ = try Peek.summary(url: url)
    }
}
