import Foundation
import Darwin
import FormatoCore

/// Axis and numeric conventions for a four-dimensional DigitalMicrograph image.
public nonisolated enum DM4GatherConvention: Sendable {
    /// RosettaSciIO 049e7d70: preserve stored C order, numeric type and all four calibrated axes.
    case rosettaSciIO
    /// The original app reader's unit-domain layout inference and Float32 conversion.
    /// Real-space leading DM dimensions imply scan-fastest storage `[Rx,Ry,Qy,Qx]`;
    /// gathers return `[Ry,Rx,Qy,Qx]`. Missing/unknown units retain detector-fastest order.
    /// Contradictory known domains retain that order and drop calibrations with `calibrationNote`.
    case appCalibratedAxes
}

/// A lazy mapped 4D image, parsed through `DM4Experiment`'s tag tree without a second DM parser.
/// The default signal preserves RosettaSciIO's stored array. The app option gathers scan-fastest storage.
/// Only requested slabs are copied. Keep the file unchanged while this reader or its signal exists.
public nonisolated struct DM4Datacube: Sendable {
    /// The selected image object. The first rank-four non-thumbnail image is used when no index is supplied.
    public let object: DM4ImageObject
    /// Array, axes and existing DMFile mapped metadata. `load()` materializes the entire cube.
    public let signal: FormatoLazySignal
    /// Why the app convention dropped contradictory calibrations; nil when calibration is retained.
    public let calibrationNote: String?

    /// Opens a rank-four real-valued DM4 image with a read-only mapping.
    /// - Parameters:
    ///   - path: DM4 filename; DM3 is outside this API.
    ///   - objectIndex: The `DM4ImageObject.index` to use, or nil to select the first rank-four image.
    ///   - convention: Stored reference order by default, or the separately pinned app layout.
    ///   - options: Existing tag-walk string limits.
    /// - Throws: `DM4Error` for malformed data, unsupported types or absence of a rank-four object.
    public init(path: String, objectIndex: Int? = nil, convention: DM4GatherConvention = .rosettaSciIO,
                options: DMReadOptions = DMReadOptions()) throws {
        let file = try DMFile(path: path, options: options)
        let tree = try DM4Experiment.tagTree(path: path, options: options)
        guard let object = file.objects.first(where: { candidate in
            if let objectIndex { return candidate.index == objectIndex }
            return candidate.dimensions.count == 4
        }) else {
            throw DM4Error.noDatacube
        }
        self.object = object
        guard object.dimensions.count == 4, object.dimensions.allSatisfy({ $0 > 0 }) else { throw DM4Error.noDatacube }
        guard let type = DMFile.dataType(code: object.dataType) else { throw DM4Error.unsupportedDataType(object.dataType) }
        let mapping = try DM4Mapping(path: path)
        guard mapping.length >= 4, mapping.pointer.loadUnaligned(as: UInt32.self).bigEndian == 4 else { throw DM4Error.noDatacube }
        let shape = Array(object.dimensions.reversed())
        let n: Int
        do { n = try FormatoArray.elementCount(shape + [type.byteSize]) } catch { throw DM4Error.truncated }
        guard object.dataOffset >= 0, object.dataOffset <= mapping.length, n <= mapping.length - object.dataOffset,
              object.dataByteCount == n else { throw DM4Error.truncated }
        var permutation = [0,1,2,3]
        var note: String?
        var axes = DMFile.axes(of: object)
        let app = convention == .appCalibratedAxes
        if app {
            // Use the public tag maps, not a second parser or size heuristics. Indices may be zero- or one-based.
            let prefix = "ImageList.\(object.index).ImageData."
            let indices = tree.numbers.keys.filter { $0.hasPrefix(prefix + "Dimensions.") }
                .compactMap { Int($0.dropFirst((prefix + "Dimensions.").count)) }.sorted()
            let units = indices.map { tree.strings[prefix + "Calibrations.Dimension.\($0).Units"] }
            let domains = units.map(axisDomain)
            var contradictory = false
            func pair(_ range: Range<Int>) -> Int? {
                let values = range.map { domains[$0] }
                guard values.allSatisfy({ $0 != nil }) else { return nil }
                let known = Set(values.compactMap { $0 })
                if known.count > 1 { contradictory = true }
                return known.first
            }
            guard domains.count == 4 else { throw DM4Error.truncated }
            let leading = pair(0..<2), trailing = pair(2..<4)
            if contradictory || (leading != nil && leading == trailing) {
                note = "Pixel calibration not imported: the DM file's axis units (\(units.map { $0 ?? "none" }.joined(separator: ", "))) do not name one real-space pair and one diffraction pair. Enter the pixel sizes by hand."
                axes = axes.map { FormatoAxis(name: $0.name, size: $0.size, scale: 1, offset: 0, units: "", navigate: $0.navigate) }
            } else if leading == 0 && trailing == 1 { permutation = [2,3,1,0] }
        }
        calibrationNote = note
        let outputShape = permutation.map { shape[$0] }
        if app {
            axes = permutation.enumerated().map { i, j in
                let a = axes[j]
                return FormatoAxis(name: ["Ry","Rx","Qy","Qx"][i], size: a.size, scale: a.scale, offset: a.offset, units: a.units, navigate: i < 2)
            }
        }
        let array = DM4GatherArray(mapping: mapping, offset: object.dataOffset, storedType: type, dataType: app ? .float32 : type,
                                  storedShape: shape, shape: outputShape, permutation: permutation)
        signal = FormatoLazySignal(title: object.name, signalType: DMFile.signalType(of: object), axes: axes,
                                  metadata: file.metadata(of: object), array: array)
    }

    /// One frame as a `[1,1,Qy,Qx]` array, indexed in this convention's first two dimensions.
    public func frame(scanY: Int, scanX: Int) throws -> FormatoArray {
        try signal.array.read(start: [scanY,scanX,0,0], count: [1,1,signal.array.shape[2],signal.array.shape[3]])
    }
}
private func axisDomain(_ units: String?) -> Int? {
    guard let units else { return nil }
    let normalized = units.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "μ", with: "µ")
    if normalized == "mrad" || normalized.contains("1/") || normalized.contains("^-1") || normalized.contains("⁻¹") { return 1 }
    return ["nm","µm","um","å","angstrom","angstroms"].contains(normalized) ? 0 : nil
}
private final class DM4Mapping: @unchecked Sendable {
    let fd: Int32; let length: Int; let pointer: UnsafeMutableRawPointer
    init(path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw DM4Error.cannotOpen(URL(fileURLWithPath: path).lastPathComponent) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= Int.max else { close(descriptor); throw DM4Error.truncated }
        let length = Int(info.st_size)
        guard let pointer = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0), pointer != MAP_FAILED else { close(descriptor); throw DM4Error.cannotOpen(URL(fileURLWithPath: path).lastPathComponent) }
        fd = descriptor; self.length = length; self.pointer = pointer
    }
    deinit { munmap(pointer, length); close(fd) }
    func checkSize() throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == length else { throw DM4Error.truncated }
    }
}
private struct DM4GatherArray: FormatoLazyArray {
    let mapping: DM4Mapping; let offset: Int; let storedType: FormatoDataType; let dataType: FormatoDataType
    let storedShape: [Int]; let shape: [Int]; let permutation: [Int]
    func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.checkSlab(start: start, count: count, shape: shape); try mapping.checkSize()
        let total = try FormatoArray.elementCount(count + [dataType.byteSize])
        var out = Data(capacity: total)
        var storedStrides = [Int](repeating: 1, count: 4)
        for i in stride(from: 2, through: 0, by: -1) { storedStrides[i] = storedStrides[i+1] * storedShape[i+1] }
        // Each destination coordinate maps independently to immutable source strides. No whole-frame intermediate.
        FormatoArray.forEachRun(start: start, count: count, shape: shape) { first, length in
            for element in first..<(first + length) {
                var remaining = element, source = 0
                for i in stride(from: 3, through: 0, by: -1) {
                    source += (remaining % shape[i]) * storedStrides[permutation[i]]
                    remaining /= shape[i]
                }
                let p = mapping.pointer + offset + source * storedType.byteSize
                if dataType == storedType {
                    out.append(p.assumingMemoryBound(to: UInt8.self), count: storedType.byteSize)
                } else {
                    let value: Float
                    switch storedType {
                    case .uint8: value = Float(p.load(as: UInt8.self))
                    case .int8: value = Float(p.load(as: Int8.self))
                    case .int16: value = Float(Int16(littleEndian: p.loadUnaligned(as: Int16.self)))
                    case .uint16: value = Float(UInt16(littleEndian: p.loadUnaligned(as: UInt16.self)))
                    case .int32: value = Float(Int32(littleEndian: p.loadUnaligned(as: Int32.self)))
                    case .uint32: value = Float(UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)))
                    case .float64: value = Float(Double(bitPattern: UInt64(littleEndian: p.loadUnaligned(as: UInt64.self))))
                    default: value = Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)))
                    }
                    var bits = value.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
                }
            }
        }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }
}
