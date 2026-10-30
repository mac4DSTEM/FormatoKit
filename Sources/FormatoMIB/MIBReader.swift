// QuantumDetector rules ported from RosettaSciIO 049e7d70 (GPL-3.0-or-later).
import Foundation
import Darwin
import FormatoCore

/// Typed failures for missing, malformed or unsupported Merlin files.
public nonisolated enum MIBError: Error, Sendable, Equatable {
    /// A file could not be opened or mapped.
    case cannotOpen(String)
    /// Invalid header, dimensions, companion metadata or file length.
    case malformed(String)
    /// An encoding or layout the pinned readers do not support.
    case unsupported(String)
}

/// Which pinned reader's scan shape, orientation and output type to use.
public nonisolated enum MIBConvention: Sendable {
    /// RosettaSciIO 049e7d70: trigger/timestamp shape, squeezed axes, flipped penultimate axis, stored integer type.
    case rosettaSciIO
    /// The original application's reader: ScanX/ScanY companion, full detector assemblies, unflipped Float32 values.
    /// Packed R64 is refused in both conventions. Explicit navigation and frame slicing are unavailable here.
    case appScanXY
}

/// Lazy, read-only memory-mapped Merlin MIB frames with a FormatoCore signal.
/// Keep the file unchanged while the reader or its signal exists. Processed U08 (1/6-bit), U16 (12-bit),
/// and U32 (24-bit) are supported. Packed R64 is refused, as in both pinned readers.
public nonisolated struct MIBReader: Sendable {
    /// Signal metadata and on-demand pixels; construction reads headers but no detector payload.
    public let signal: FormatoLazySignal
    /// The stored pixel code of the first frame header: `U08`, `U16` or `U32` (the type the signal is read from).
    public let pixelCode: String

    /// Opens a MIB file and its optional same-stem `.hdr` companion.
    /// - Parameters:
    ///   - path: MIB filename.
    ///   - navigationShape: Fastest-first navigation extents, like RosettaSciIO's tuple. Nil infers them.
    ///   - firstFrame: Inclusive frame index, with Python negative indexing.
    ///   - lastFrame: Exclusive frame index, with Python negative indexing.
    ///   - convention: Reference behavior by default; the app compatibility option is pinned separately.
    /// - Throws: `MIBError` for malformed files and unsupported layouts, including R64.
    public init(path: String, navigationShape: [Int]? = nil, firstFrame: Int? = nil, lastFrame: Int? = nil,
                convention: MIBConvention = .rosettaSciIO) throws {
        let mapping = try MIBMapping(path: path, anyHeaderSize: convention == .appScanXY)
        let header = try mapping.header(at: 0)
        pixelCode = header.code
        if header.code == "R64" { throw MIBError.unsupported("RAW MIB data not supported.") }
        let type: FormatoDataType
        switch header.code {
        case "U08": type = .uint8
        case "U16": type = .uint16
        case "U32": type = .uint32
        default: throw MIBError.unsupported("MIB pixel encoding \(header.code)")
        }
        let pixelBytes = try product([header.width, header.height, type.byteSize])
        let (stride, overflow) = pixelBytes.addingReportingOverflow(header.size)
        guard !overflow, mapping.length >= stride, mapping.length % stride == 0 else { throw MIBError.malformed("Incomplete frame") }
        let frames = mapping.length / stride
        let hdrPath = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("hdr")
        var fields: [String: String] = [:]
        if FileManager.default.fileExists(atPath: hdrPath.path) {
            let text: String
            do { text = try String(contentsOf: hdrPath, encoding: .utf8) } catch { throw MIBError.cannotOpen(hdrPath.lastPathComponent) }
            for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("HDR") && !line.hasPrefix("End\t") {
                let pair = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { throw MIBError.malformed("Invalid hdr line") }
                fields[String(pair[0]).trimmingCharacters(in: CharacterSet(charactersIn: ": "))] = String(pair[1])
            }
        }
        func positive(_ key: String) throws -> Int {
            guard let text = fields[key], let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else { throw MIBError.malformed("Invalid \(key)") }
            return value
        }
        let shape: [Int], first: Int
        let flip: Bool, outputType: FormatoDataType
        if convention == .appScanXY {
            guard navigationShape == nil, firstFrame == nil, lastFrame == nil else { throw MIBError.unsupported("App convention does not slice frames") }
            let dimensions: Int
            switch header.layout {
            case "1x1": dimensions = 256
            case "2x2": dimensions = 512
            case "2x2G": dimensions = 514
            default: throw MIBError.unsupported("App detector assembly \(header.layout)")
            }
            guard header.width == dimensions, header.height == dimensions else { throw MIBError.malformed("Detector dimensions disagree with assembly") }
            let x = try positive("ScanX"), y = try positive("ScanY")
            guard try product([x,y]) == frames else { throw MIBError.malformed("ScanX/ScanY do not match file") }
            shape = [y,x,dimensions,dimensions]; first = 0; flip = false; outputType = .float32
        } else {
            func index(_ value: Int?, fallback: Int) -> Int {
                guard let value else { return fallback }
                return value < 0 ? max(0, frames + max(value, -frames)) : min(value, frames)
            }
            first = index(firstFrame, fallback: 0)
            let last = index(lastFrame, fallback: frames)
            guard last > first else { throw MIBError.malformed("Empty frame slice") }
            var nav = navigationShape
            if nav == nil {
                var trigger = 1, total = frames
                if !fields.isEmpty {
                    guard let triggerText = fields["Frames per Trigger (Number)"], let t = Int(triggerText), t >= 0 else { throw MIBError.malformed("Invalid trigger count") }
                    trigger = t
                    guard let value = fields["Frames in Acquisition (Number)"], let n = Int(value), n >= 0 else { throw MIBError.malformed("Invalid acquisition frame count") }
                    total = n
                    guard trigger > 0 || total == 0 else { throw MIBError.malformed("Zero trigger count") }
                }
                if trigger == 1 {
                    var times: [Int64] = []
                    for i in 0..<min(frames, 10000) { times.append(try timestampNanoseconds(mapping.header(at: i * stride).timestamp)) }
                    let differences = try zip(times.dropFirst(), times).map { a, b -> Double in
                        let (difference, overflow) = a.subtractingReportingOverflow(b)
                        guard !overflow else { throw MIBError.malformed("Timestamp interval overflows") }
                        return Double(difference)
                    }
                    if !differences.isEmpty {
                        let mean = differences.reduce(0,+) / Double(differences.count)
                        if let i = differences.firstIndex(where: { $0 - mean > 0 }) { trigger = i + 1 }
                    }
                }
                if total != 0 { nav = [trigger, total / trigger] }
            }
            var navigation = [last - first]
            if let nav {
                let requested = try product(nav)
                if requested > frames {
                    if first == 0 && nav.count > 1 { navigation = [frames / nav[0], nav[0]] }
                } else if last - first >= requested { navigation = Array(nav.reversed()) }
            }
            shape = (navigation + [header.height, header.width]).filter { $0 != 1 }
            guard shape.count >= 2 else { throw MIBError.unsupported("Squeezed MIB needs at least two axes for the reference flip") }
            flip = true; outputType = type
        }
        _ = try product(shape + [outputType.byteSize])
        let axes = shape.enumerated().map { i,n in FormatoAxis(name: "", size: n, scale: 1, offset: 0, units: "", navigate: i < shape.count - 2) }
        var metadata = FormatoMetadata()
        let file = URL(fileURLWithPath: path).lastPathComponent
        func entry(_ key: String, _ value: FormatoValue, _ source: String) {
            metadata.set(FormatoMetadataEntry(key: key, value: value, units: nil,
                provenance: FormatoProvenance(file: file, source: source, rule: "rsciio quantumdetector file_reader")))
        }
        let date = header.timestamp.components(separatedBy: "T")
        guard date.count == 2 else { throw MIBError.malformed("Invalid timestamp") }
        entry("General.original_filename", .text(file), "filename")
        entry("General.date", .text(date[0]), "MIB timestamp")
        entry("General.time", .text(date[1].trimmingCharacters(in: CharacterSet(charactersIn: "Z"))), "MIB timestamp")
        if date[1].contains("Z") { entry("General.time_zone", .text("UTC"), "MIB timestamp") }
        entry("Signal.signal_type", .text("electron_diffraction"), "MIB format")
        entry("Acquisition_instrument.dwell_time", .number(header.exposure * 1e-3), "MIB exposure ns / 1e6 * 1e-3")
        signal = FormatoLazySignal(title: "", signalType: "electron_diffraction", axes: axes, metadata: metadata,
            array: MIBArray(mapping: mapping, header: header, storedType: type, dataType: outputType, shape: shape, first: first, stride: stride, flip: flip))
    }
}

private func product(_ shape: [Int]) throws -> Int {
    guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 }) else { throw MIBError.malformed("Invalid dimensions") }
    do { return try FormatoArray.elementCount(shape) } catch { throw MIBError.malformed("Dimensions overflow") }
}
private func timestampNanoseconds(_ text: String) throws -> Int64 {
    // Parse fractional seconds as integers, avoiding loss of scan timing at contemporary epoch values.
    let parts = text.replacingOccurrences(of: "Z", with: "").split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { throw MIBError.malformed("Invalid timestamp") }
    // `ISO8601DateFormatter` costs tens of microseconds a call (ICU); the plain "YYYY-MM-DDTHH:MM:SS" every Merlin writes is
    // computed directly (a proleptic Gregorian day count), anything else goes through the formatter as before.
    let seconds: Double
    if let direct = mibPlainUTCSeconds(String(parts[0])) {
        seconds = direct
    } else {
        guard let date = ISO8601DateFormatter().date(from: String(parts[0]) + "Z") else { throw MIBError.malformed("Invalid timestamp") }
        seconds = date.timeIntervalSince1970
    }
    guard seconds.isFinite, abs(seconds) < 9e9 else { throw MIBError.malformed("Timestamp outside supported range") }
    let fraction = parts.count == 2 ? String(parts[1]) : ""
    guard fraction.count <= 9, fraction.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let ns = Int64(fraction + String(repeating: "0", count: 9 - fraction.count)) else { throw MIBError.malformed("Invalid timestamp fraction") }
    return Int64(seconds) * 1_000_000_000 + ns
}
/// Seconds since 1970 of "YYYY-MM-DDTHH:MM:SS" read as UTC, or nil for any other shape or an impossible date or time.
package func mibPlainUTCSeconds(_ text: String) -> Double? {
    let b = Array(text.utf8)
    guard b.count == 19, b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58 else { return nil }
    func number(_ range: Range<Int>) -> Int? {
        var v = 0
        for i in range { guard b[i] >= 48, b[i] <= 57 else { return nil }; v = v * 10 + Int(b[i] - 48) }
        return v
    }
    guard let y = number(0..<4), let mo = number(5..<7), let d = number(8..<10), let h = number(11..<13), let mi = number(14..<16),
          let s = number(17..<19), y >= 1, (1...12).contains(mo), h < 24, mi < 60, s < 60 else { return nil }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard d >= 1, d <= days[mo - 1] else { return nil }
    // days from civil (Howard Hinnant)
    let yy = mo <= 2 ? y - 1 : y
    let era = yy / 400
    let yoe = yy - era * 400
    let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let day = era * 146097 + doe - 719468
    return Double(day * 86400 + h * 3600 + mi * 60 + s)
}
private struct MIBHeader {
    let size: Int; let width: Int; let height: Int; let code: String; let layout: String; let timestamp: String; let exposure: Double
}
// Immutable mapping; lifetime is retained by the signal and reads use no shared mutable cursor.
private final class MIBMapping: @unchecked Sendable {
    let fd: Int32; let pointer: UnsafeMutableRawPointer; let length: Int
    /// RosettaSciIO's two header sizes only (false), or any size from 384 to 64 KiB (the original app's reader; true).
    let anyHeaderSize: Bool
    init(path: String, anyHeaderSize: Bool) throws {
        self.anyHeaderSize = anyHeaderSize
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw MIBError.cannotOpen(path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= Int.max else { close(descriptor); throw MIBError.malformed("Empty or unreadable file") }
        let size = Int(info.st_size)
        guard let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), address != MAP_FAILED else { close(descriptor); throw MIBError.cannotOpen(path) }
        fd = descriptor; pointer = address; length = size
    }
    deinit { munmap(pointer, length); close(fd) }
    func checkSize() throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == length else { throw MIBError.malformed("File size changed") }
    }
    func header(at offset: Int) throws -> MIBHeader {
        guard offset >= 0, offset <= length, length - offset >= 384 else { throw MIBError.malformed("Truncated header") }
        let prefix = String(decoding: UnsafeRawBufferPointer(start: pointer + offset, count: 384), as: UTF8.self).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard prefix.count >= 8, prefix[0] == "MQ1", let size = Int(prefix[2]),
              anyHeaderSize ? (384...65536).contains(size) : [384,768].contains(size), size <= length - offset else { throw MIBError.malformed("Invalid MIB header") }
        let bytes = UnsafeRawBufferPointer(start: pointer + offset, count: size)
        guard bytes.allSatisfy({ $0 < 128 }) else { throw MIBError.malformed("Non-ASCII header") }
        let fields = String(decoding: bytes, as: UTF8.self).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 11, let w = Int(fields[4]), let h = Int(fields[5]), w > 0, h > 0 else { throw MIBError.malformed("Invalid detector shape") }
        let exposure = fields[fields.count - 3]
        guard exposure.hasSuffix("ns"), let value = Double(exposure.dropLast(2)), value.isFinite, value >= 0 else { throw MIBError.malformed("Invalid exposure") }
        return MIBHeader(size: size, width: w, height: h, code: fields[6], layout: fields[7].trimmingCharacters(in: .whitespaces), timestamp: fields[fields.count - 4], exposure: value / 1e6)
    }
}
private struct MIBArray: FormatoLazyArray {
    let mapping: MIBMapping; let header: MIBHeader; let storedType: FormatoDataType
    let dataType: FormatoDataType; let shape: [Int]; let first: Int; let stride: Int; let flip: Bool
    func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape); try mapping.checkSize()
        let elements = try FormatoArray.elementCount(count)
        let outSize = dataType.byteSize, inSize = storedType.byteSize
        var bytes = Data(count: elements * outSize)
        let framePixels = header.height * header.width
        var checkedFrame = -1
        var failure: MIBError?
        var written = 0
        bytes.withUnsafeMutableBytes { out in
            FormatoArray.forEachContiguousRun(start: start, count: count, shape: shape) { element, length in
                guard failure == nil else { return }
                // A run is cut where the source leaves a frame or the flip's row changes, so each piece is contiguous in the file.
                var i = element
                var remaining = length
                while remaining > 0 {
                    var source = i
                    var piece = remaining
                    if flip {
                        let stride = shape.last!, axis = shape[shape.count - 2]
                        let coordinate = (i / stride) % axis
                        source += (axis - 1 - 2 * coordinate) * stride
                        piece = min(piece, stride - i % stride)
                    }
                    let frame = first + source / framePixels, pixel = source % framePixels
                    piece = min(piece, framePixels - pixel)
                    if frame != checkedFrame {
                        do {
                            let actual = try mapping.header(at: frame * stride)
                            guard actual.size == header.size, actual.width == header.width, actual.height == header.height, actual.code == header.code else { throw MIBError.malformed("Frame header changed layout") }
                            checkedFrame = frame
                        } catch let error as MIBError { failure = error; return } catch { failure = .malformed("Invalid frame"); return }
                    }
                    let base = mapping.pointer + frame * stride + header.size + pixel * inSize
                    let destination = out.baseAddress! + written * outSize
                    switch (storedType, dataType) {
                    case (.uint8, .uint8):
                        destination.copyMemory(from: base, byteCount: piece)
                    case (.uint16, .uint16):
                        // Big-endian in the file, little-endian out: swap in 16-bit lanes.
                        let dst = destination.assumingMemoryBound(to: UInt16.self)
                        if Int(bitPattern: base) % 2 == 0 {
                            let src = base.assumingMemoryBound(to: UInt16.self)
                            for k in 0..<piece { dst[k] = src[k].byteSwapped }
                        } else {
                            for k in 0..<piece { dst[k] = UInt16(bigEndian: base.loadUnaligned(fromByteOffset: 2 * k, as: UInt16.self)).littleEndian }
                        }
                    case (.uint32, .uint32):
                        let dst = destination.assumingMemoryBound(to: UInt32.self)
                        for k in 0..<piece { dst[k] = UInt32(bigEndian: base.loadUnaligned(fromByteOffset: 4 * k, as: UInt32.self)).littleEndian }
                    default:
                        for k in 0..<piece {
                            let pointer = base + k * inSize
                            let value: UInt32
                            switch storedType {
                            case .uint8: value = UInt32(pointer.load(as: UInt8.self))
                            case .uint16: value = UInt32(UInt16(bigEndian: pointer.loadUnaligned(as: UInt16.self)))
                            default: value = UInt32(bigEndian: pointer.loadUnaligned(as: UInt32.self))
                            }
                            var little = dataType == .float32 ? Float(value).bitPattern.littleEndian : value.littleEndian
                            withUnsafeBytes(of: &little) { (destination + k * outSize).copyMemory(from: $0.baseAddress!, byteCount: outSize) }
                        }
                    }
                    i += piece; remaining -= piece; written += piece
                }
            }
        }
        if let failure { throw failure }
        return try FormatoArray(dataType: dataType, shape: count, bytes: bytes)
    }
}
