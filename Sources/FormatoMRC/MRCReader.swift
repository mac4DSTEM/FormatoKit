//
//  MRCReader.swift
//  MRC / MRC2014 images and stacks as RosettaSciIO 049e7d70 `mrc/_api.py` `file_reader` reads them (no DE movie files, no
//  virtual or external images): the standard header little-endian whatever the machine stamp says (`endianness="<"`), the
//  data after `NEXT` extended-header bytes, shape (NZ, NY, NX) with every size-1 axis squeezed away, axes named z / y / x
//  in nanometres. Modes 0 (uint8, as RosettaSciIO reads it: not signed), 1, 2 and 6 are read, lazily and in the stored
//  byte order; 4 (complex64) and 12 (float16) have no FormatoDataType and are refused by name.
//
//  Scales (non-FEI): cell length / sampling / 10 per axis (Angstrom to nm), computed in double as NumPy promotes
//  float32 / uint32; 1 where the sampling (or, for z, the length) is 0; offsets are the header origins / 10. A header
//  whose NEXT is exactly 128 * 1024 bytes and whose 1024 records fit is an FEI header: every scale is 1 for z and
//  `pixel_size` * 1e9 for y and x (float32 arithmetic, as NumPy 2 evaluates a float32 scalar times a Python int), offsets 0.
//  The units list [None, "nm", "nm"], the names and the navigate flags are indexed by position from the end after the
//  squeeze, so a squeezed y axis shifts them (RosettaSciIO's behaviour, kept).
//
//  The named option for the first consumer's rules is `MRCAppImage` (docs/parity.md).
//

import Foundation
import FormatoCore

/// An MRC or MRC2014 file read as RosettaSciIO reads it: one lazy signal, size-1 axes squeezed, axes in nanometres.
public nonisolated struct MRCReader: Sendable {
    /// The file's values, axes and metadata; nothing past the header is read until it is loaded or sliced.
    public let signal: FormatoLazySignal

    /// Opens the file at `path` lazily (the header and nothing else is read).
    /// - Throws: ``MRCError`` for a header that is no MRC header, a mode that is not read, a file shorter than its
    ///   header claims; `FormatoReadError` when it cannot be opened.
    public init(path: String) throws {
        let name = formatoDisplayFileName(path)
        let file: Data
        do { file = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
            throw FormatoReadError.cannotOpen(name, error.localizedDescription)
        }
        guard file.count >= 1024 else { throw MRCError.notMRC("\(file.count) bytes, shorter than an MRC header") }
        let h = MRCHeaderBytes(file)
        let nx = Int(h.u32(0)), ny = Int(h.u32(4)), nz = Int(h.u32(8)), mode = Int(h.u32(12))
        let type: FormatoDataType
        switch mode {
        case 0: type = .uint8
        case 1: type = .int16
        case 2: type = .float32
        case 6: type = .uint16
        case 4: throw FormatoReadError.unsupportedDataType("MRC mode 4 (complex64)")
        case 12: throw FormatoReadError.unsupportedDataType("MRC mode 12 (float16)")
        default: throw MRCError.mode(mode)
        }
        let next = Int(h.u32(92))
        let offset = 1024 + next
        let dims = [nz, ny, nx]
        var count = 1
        for d in dims {
            let (p, o) = count.multipliedReportingOverflow(by: d)
            guard !o else { throw MRCError.truncated }
            count = p
        }
        let (bytes, o2) = count.multipliedReportingOverflow(by: type.byteSize)
        guard !o2, offset <= file.count, bytes <= file.count - offset else { throw MRCError.truncated }

        let isFEI = next == 128 * 1024 && file.count >= offset
        var scales: [Double], offsets: [Double]
        if isFEI {
            let pixel = Float(bitPattern: MRCHeaderBytes(file, base: 1024).u32(44))
            let nm = Double(pixel * Float(1e9))
            scales = [1, nm, nm]
            offsets = [0, 0, 0]
        } else {
            func f(_ at: Int) -> Double { Double(Float(bitPattern: h.u32(at))) }
            let mx = Double(h.u32(28)), my = Double(h.u32(32)), mz = Double(h.u32(36))
            scales = [f(48) != 0 && mz != 0 ? f(48) / mz / 10 : 1,
                      my != 0 ? f(44) / my / 10 : 1,
                      mx != 0 ? f(40) / mx / 10 : 1]
            offsets = [f(204) / 10, f(200) / 10, f(196) / 10]
        }
        let units = ["", "nm", "nm"], names = ["z", "y", "x"], navigate = [true, false, false]
        let shape = dims.filter { $0 != 1 }
        guard !shape.isEmpty else { throw FormatoReadError.unsupported("\(name) holds a single value.") }
        let rank = shape.count
        let axes = (0..<rank).map { i in
            let k = i + 3 - rank
            return FormatoAxis(name: names[k], size: shape[i], scale: scales[k], offset: offsets[k], units: units[k], navigate: navigate[k])
        }
        var metadata = FormatoMetadata()
        metadata.set(FormatoMetadataEntry(key: "General.original_filename", value: .text(name), units: nil,
            provenance: FormatoProvenance(file: name, source: "(the file name)", rule: "rsciio mrc: os.path.split(filename)[1]")))
        metadata.set(FormatoMetadataEntry(key: "Signal.signal_type", value: .text(""), units: nil,
            provenance: FormatoProvenance(file: name, source: "(constant)", rule: "rsciio mrc: signal_type is \"\"")))
        signal = FormatoLazySignal(title: "", signalType: "", axes: axes, metadata: metadata,
                                   array: FormatoFileArray(path: path, offset: offset, dataType: type, shape: shape))
    }
}

/// 32-bit little-endian words of a header (RosettaSciIO ignores the machine stamp).
nonisolated struct MRCHeaderBytes {
    let data: Data
    let base: Int
    init(_ data: Data, base: Int = 0) { self.data = data; self.base = base }
    func u32(_ offset: Int) -> UInt32 {
        let s = data.startIndex + base + offset
        return UInt32(data[s]) | UInt32(data[s + 1]) << 8 | UInt32(data[s + 2]) << 16 | UInt32(data[s + 3]) << 24
    }
}
