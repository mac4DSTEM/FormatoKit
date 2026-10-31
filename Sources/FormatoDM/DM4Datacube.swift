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

/// How the pixel bytes are held while the reader lives.
public nonisolated enum DM4DatacubeStorage: Sendable {
    /// Read-only `mmap` of the file (default). The file must stay unchanged while the reader or its signal exists.
    case mapped
    /// The object's pixel bytes are read into memory once, at open. Use for files on network or removable volumes, where a
    /// mapping can fault or change under the reader. Needs as much memory as the object; the file may change afterwards.
    case readIntoMemory
}

/// The storage layout `DM4Datacube` chose: what the unit-domain rule decided, so a consumer need not repeat it.
public nonisolated struct DM4DatacubeLayout: Sendable, Equatable {
    /// The stored shape in C order (the file's dimensions reversed; for a scan-shaped rank-three object, its stack axis
    /// split into `[scanY, scanX]`).
    public let storedShape: [Int]
    /// Output axis `i` is stored axis `permutation[i]`. `[0,1,2,3]` unless the app convention found scan-fastest storage.
    public let permutation: [Int]
    /// True when the app convention found real-space dimensions leading in the file, so the stored order is `[Rx,Ry,Qy,Qx]`
    /// in the file's terms and the output is `[Ry,Rx,Qy,Qx]`.
    public var scanFastest: Bool { permutation != [0,1,2,3] }
    /// The stored element type of the file.
    public let storedType: FormatoDataType
    /// The element type the arrays return (Float32 for the app convention, the stored type otherwise).
    public let outputType: FormatoDataType
}

/// A lazy mapped 4D image, parsed through `DM4Experiment`'s tag tree without a second DM parser.
/// The default signal preserves RosettaSciIO's stored array. The app option gathers scan-fastest storage.
/// Only requested slabs are copied. Keep the file unchanged while this reader or its signal exists.
public nonisolated struct DM4Datacube: Sendable {
    /// The selected image object: with no index, the first in `ImageList` order that is rank four, or rank three with
    /// scan-shape tags (see `init`).
    public let object: DM4ImageObject
    /// Array, axes and existing DMFile mapped metadata. `load()` materializes the entire cube.
    public let signal: FormatoLazySignal
    /// Why the app convention dropped contradictory calibrations; nil when calibration is retained.
    public let calibrationNote: String?
    /// The storage layout the convention chose.
    public let layout: DM4DatacubeLayout

    /// Opens a rank-four real-valued DM4 image with a read-only mapping.
    ///
    /// A rank-three object `(N, Qy, Qx)` is read as the four-dimensional `[scanY, scanX, Qy, Qx]` when the file's
    /// "Scan shape X" and "Scan shape Y" tags multiply to `N` (py4DSTEM's NCEM TitanX reshape, without its two-pixel roll):
    /// the bytes as stored, both scan axes calibrated as the stack axis. Tags under the object's own `ImageTags` win over
    /// tags elsewhere in the file.
    /// - Parameters:
    ///   - path: DM3 or DM4 filename.
    ///   - objectIndex: The `DM4ImageObject.index` to use, or nil to select the first datacube.
    ///   - convention: Stored reference order by default, or the separately pinned app layout.
    ///   - options: Existing tag-walk string limits.
    ///   - storage: `.mapped` (default) or `.readIntoMemory`.
    /// - Throws: `DM4Error` for malformed data, unsupported types or absence of a datacube; `.cannotOpen` with a sentence
    ///   for an object of more than four dimensions.
    public init(path: String, objectIndex: Int? = nil, convention: DM4GatherConvention = .rosettaSciIO,
                options: DMReadOptions = DMReadOptions(), storage: DM4DatacubeStorage = .mapped) throws {
        let file = try DMFile(path: path, options: options)
        let tree = try DM4Experiment.tagTree(path: path, options: options)
        func scanShape(_ candidate: DM4ImageObject) -> (y: Int, x: Int)? {
            guard candidate.dimensions.count == 3 else { return nil }
            let own = "ImageList.\(candidate.index).ImageTags."
            func tag(_ needle: String) -> Int? {
                let keys = tree.numbers.keys.filter { $0.contains(needle) }.sorted()
                return (keys.first { $0.hasPrefix(own) } ?? keys.first).flatMap { tree.numbers[$0] }.flatMap { Int(exactly: $0) }
            }
            guard let x = tag("Scan shape X"), let y = tag("Scan shape Y"), x > 0, y > 0 else { return nil }
            let (n, overflow) = x.multipliedReportingOverflow(by: y)
            return !overflow && n == candidate.dimensions[2] ? (y, x) : nil
        }
        func tooManyDimensions(_ candidate: DM4ImageObject) -> DM4Error {
            .cannotOpen("image object \(candidate.index) (\(candidate.name)) has \(candidate.dimensions.count) dimensions; a datacube has four, or three with scan-shape tags.")
        }
        let chosen: DM4ImageObject
        if let objectIndex {
            guard let candidate = file.objects.first(where: { $0.index == objectIndex }) else { throw DM4Error.noDatacube }
            chosen = candidate
        } else {
            guard let candidate = file.objects.first(where: { $0.dimensions.count == 4 || scanShape($0) != nil }) else {
                if let big = file.objects.first(where: { $0.dimensions.count > 4 }) { throw tooManyDimensions(big) }
                throw DM4Error.noDatacube
            }
            chosen = candidate
        }
        let object = chosen
        self.object = object
        if object.dimensions.count > 4 { throw tooManyDimensions(object) }
        let scan = scanShape(object)
        guard object.dimensions.count == 4 || scan != nil, object.dimensions.allSatisfy({ $0 > 0 }) else { throw DM4Error.noDatacube }
        guard let type = DMFile.dataType(code: object.dataType) else { throw DM4Error.unsupportedDataType(object.dataType) }
        let shape = scan.map { [$0.y, $0.x, object.dimensions[1], object.dimensions[0]] } ?? Array(object.dimensions.reversed())
        let n: Int
        do { n = try FormatoArray.elementCount(shape + [type.byteSize]) } catch { throw DM4Error.truncated }
        // A declared data length of 0 is tolerated (the tag says nothing): the dimensions give the length.
        guard object.dataOffset >= 0, object.dataByteCount == n || object.dataByteCount == 0 else { throw DM4Error.truncated }
        let mapping = try DM4Mapping(path: path, storage: storage, dataOffset: object.dataOffset, dataBytes: n)
        var permutation = [0,1,2,3]
        var note: String?
        var axes = DMFile.axes(of: object)
        if let scan {
            // [N, Qy, Qx] -> [scanY, scanX, Qy, Qx]: both scan axes take the stack axis's calibration, named and navigated as
            // the first two axes of a four-dimensional object are.
            let stack = axes[0]
            axes = [FormatoAxis(name: nil, size: scan.y, scale: stack.scale, offset: stack.offset, units: stack.units, navigate: true),
                    FormatoAxis(name: "z", size: scan.x, scale: stack.scale, offset: stack.offset, units: stack.units, navigate: true),
                    axes[1], axes[2]]
        }
        let app = convention == .appCalibratedAxes
        // The unit-domain rule is for a stored rank-four object; a reshaped stack is detector-fastest by construction.
        if app && scan == nil {
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
        layout = DM4DatacubeLayout(storedShape: shape, permutation: permutation, storedType: type, outputType: app ? .float32 : type)
        let array = DM4GatherArray(mapping: mapping, offset: mapping.dataStart, storedType: type, dataType: app ? .float32 : type,
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
    /// Where the pixel bytes start, relative to `pointer`.
    let dataStart: Int
    let pointer: UnsafeMutableRawPointer
    private let mapped: Bool
    private let fd: Int32
    private let length: Int
    init(path: String, storage: DM4DatacubeStorage, dataOffset: Int, dataBytes: Int) throws {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw DM4Error.cannotOpen(name) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= Int.max else { close(descriptor); throw DM4Error.truncated }
        let fileLength = Int(info.st_size)
        var version: UInt32 = 0
        guard fileLength >= 4, pread(descriptor, &version, 4, 0) == 4, [3, 4].contains(UInt32(bigEndian: version)),
              dataOffset <= fileLength, dataBytes <= fileLength - dataOffset else { close(descriptor); throw DM4Error.truncated }
        switch storage {
        case .mapped:
            guard let p = mmap(nil, fileLength, PROT_READ, MAP_PRIVATE, descriptor, 0), p != MAP_FAILED else { close(descriptor); throw DM4Error.cannotOpen(name) }
            fd = descriptor; length = fileLength; pointer = p; dataStart = dataOffset; mapped = true
        case .readIntoMemory:
            guard let buffer = malloc(max(dataBytes, 1)) else { close(descriptor); throw DM4Error.truncated }
            var done = 0
            while done < dataBytes {
                let got = pread(descriptor, buffer + done, min(dataBytes - done, 1 << 30), off_t(dataOffset + done))
                if got < 0 && errno == EINTR { continue }
                if got <= 0 { free(buffer); close(descriptor); throw DM4Error.truncated }
                done += got
            }
            close(descriptor)
            fd = -1; length = dataBytes; pointer = buffer; dataStart = 0; mapped = false
        }
    }
    deinit {
        if mapped { munmap(pointer, length); close(fd) } else { free(pointer) }
    }
    func checkSize() throws {
        guard mapped else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == length else { throw DM4Error.truncated }
    }
}
private struct DM4GatherArray: FormatoLazyArray {
    let mapping: DM4Mapping; let offset: Int; let storedType: FormatoDataType; let dataType: FormatoDataType
    let storedShape: [Int]; let shape: [Int]; let permutation: [Int]
    func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape); try mapping.checkSize()
        let elements = try FormatoArray.elementCount(count)
        let total = try FormatoArray.elementCount(count + [dataType.byteSize])
        var out = Data(count: total)
        guard elements > 0 else { return try FormatoArray(dataType: dataType, shape: count, bytes: out) }
        var storedStrides = [Int](repeating: 1, count: 4)
        for i in stride(from: 2, through: 0, by: -1) { storedStrides[i] = storedStrides[i+1] * storedShape[i+1] }
        // Source stride (in elements) of each output axis; the last axis is one element apart when nothing is permuted.
        let outStrides = (0..<4).map { storedStrides[permutation[$0]] }
        let inner = shape[3], innerStride = outStrides[3]
        let storedSize = storedType.byteSize, outSize = dataType.byteSize
        let base = mapping.pointer + offset
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var dst = raw.baseAddress!
            // Rows of the last output axis, left to right in the slab: one source start per row, then a constant stride.
            FormatoArray.forEachContiguousRun(start: start, count: count, shape: shape) { first, length in
                var element = first, remaining = length
                while remaining > 0 {
                    let column = element % inner
                    let n = min(remaining, inner - column)
                    var rest = element - column, source = column * innerStride
                    // rest is a multiple of `inner`: decode the three leading axes.
                    rest /= inner
                    for axis in stride(from: 2, through: 0, by: -1) {
                        source += (rest % shape[axis]) * outStrides[axis]; rest /= shape[axis]
                    }
                    let from = base + source * storedSize
                    if dataType == storedType {
                        if innerStride == 1 { memcpy(dst, from, n * storedSize) }
                        else { for k in 0..<n { memcpy(dst + k * outSize, from + k * innerStride * storedSize, storedSize) } }
                    } else {
                        convertToFloat32(storedType, from: from, strideBytes: innerStride * storedSize, count: n, into: dst)
                    }
                    dst += n * outSize; element += n; remaining -= n
                }
            }
        }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }
}
/// Little-endian stored values to Float32 (same conversions as before: Float(Int/UInt) rounds to nearest, Double narrows).
private func convertToFloat32(_ type: FormatoDataType, from: UnsafeRawPointer, strideBytes: Int, count: Int, into dst: UnsafeMutableRawPointer) {
    let out = dst.assumingMemoryBound(to: UInt32.self)
    @inline(__always) func run(_ value: (UnsafeRawPointer) -> Float) {
        var p = from
        for k in 0..<count { out[k] = value(p).bitPattern.littleEndian; p += strideBytes }
    }
    switch type {
    case .uint8: run { Float($0.load(as: UInt8.self)) }
    case .int8: run { Float($0.load(as: Int8.self)) }
    case .int16: run { Float(Int16(littleEndian: $0.loadUnaligned(as: Int16.self))) }
    case .uint16: run { Float(UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))) }
    case .int32: run { Float(Int32(littleEndian: $0.loadUnaligned(as: Int32.self))) }
    case .uint32: run { Float(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    case .float64: run { Float(Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)))) }
    default: run { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    }
}
