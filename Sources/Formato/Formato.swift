//
//  Formato.swift
//  Role: The umbrella product: one `FormatoLoader.load(path:)` that finds out which format a file is (RosettaSciIO's `load` guesses
//        from the extension, then the plugin checks the content) and returns its signals the way that format's module does.
//        Detection: the extension picks the candidates, the first bytes confirm them (TIFF and HDF5 signatures, DM's version word,
//        Velox's `Version` dataset); a file whose extension and bytes disagree is `.unknown`. Formats whose data are not signals
//        (4D datacubes: EMPAD, MIB, py4DSTEM HDF5) are named, not loaded: they have dedicated readers with their own options.
//

import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoMRC
import FormatoMSA
import FormatoTIFF

public nonisolated enum FormatoFileKind: Sendable, Equatable {
    case digitalMicrograph
    case veloxEMD
    case tiff
    case mrc
    case msa
    /// EMPAD XML (+ raw): read with `EMPADReader`.
    case empad
    /// Merlin MIB: read with `MIBReader`.
    case merlinMIB
    /// HDF5 that is not a Velox file (py4DSTEM / NCEM EMD, hspy, ...): `HDF5Datacube` reads the 4D datacubes.
    case hdf5
    case unknown
}

public nonisolated enum FormatoLoadError: Error, Equatable, LocalizedError {
    /// The file is of a kind with its own reader (a 4D datacube, not signals).
    case useDedicatedReader(FormatoFileKind, String)
    case unknownFormat(String)

    public var errorDescription: String? {
        switch self {
        case .useDedicatedReader(_, let what): return what
        case .unknownFormat(let name): return "\(name) is not a format FormatoKit reads (or its extension and its first bytes disagree)."
        }
    }
}

public nonisolated enum FormatoLoader {
    /// The kind of `path`: its extension (case-insensitive, as RosettaSciIO's plugin table), confirmed by the file's first bytes.
    public static func sniff(path: String) -> FormatoFileKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        let bytes = [UInt8](head)
        func isHDF5() -> Bool { bytes.starts(with: [0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]) }
        switch ext {
        case "dm3", "dm4":
            // The version word, big-endian: 3 or 4.
            return bytes.count >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && (bytes[3] == 3 || bytes[3] == 4) ? .digitalMicrograph : .unknown
        case "tif", "tiff":
            let le = bytes.starts(with: [0x49, 0x49]), be = bytes.starts(with: [0x4D, 0x4D])
            guard bytes.count >= 4, le || be else { return .unknown }
            let magic = le ? Int(bytes[2]) | Int(bytes[3]) << 8 : Int(bytes[2]) << 8 | Int(bytes[3])
            return magic == 42 || magic == 43 ? .tiff : .unknown
        case "mrc", "ali": return bytes.count >= 4 ? .mrc : .unknown
        case "msa", "ems", "mas", "emsa": return .msa
        case "mib": return .merlinMIB
        case "xml": return .empad
        case "emd", "h5", "hdf5":
            guard isHDF5() else { return .unknown }
            return VeloxEMDReader.hasVeloxVersion(path: path) ? .veloxEMD : .hdf5
        default: return .unknown
        }
    }

    /// The signals of `path`, in the order the format's module returns them; a signal FormatoKit refuses is its error, the others
    /// still load (for DM, one result per image object; for Velox, single spectra, then images, then spectrum images).
    /// Throws `FormatoLoadError` for a kind with a dedicated reader or an unknown file, and the module's error where the file cannot
    /// be listed at all.
    public static func load(path: String) throws -> [Result<FormatoLazySignal, any Error>] {
        let name = formatoDisplayFileName(path)
        switch sniff(path: path) {
        case .digitalMicrograph:
            let dm = try DMFile(path: path)
            return dm.objects.map { object in Result { try dm.signal(index: object.index) } }
        case .veloxEMD:
            var out: [Result<FormatoLazySignal, any Error>] = []
            func memory(_ s: FormatoSignal) -> Result<FormatoLazySignal, any Error> {
                .success(FormatoLazySignal(title: s.title, signalType: s.signalType, axes: s.axes, metadata: s.metadata, array: FormatoInMemoryArray(s.data)))
            }
            out += try VeloxSpectrumSignals(path: path).signals.map(memory)
            let images = try VeloxImageSignals(path: path)
            out += images.images.map { image in Result { try images.signal(image) } }
            do { out += try VeloxSpectrumImageSignals(path: path).signals.map(memory) } catch { out.append(.failure(error)) }
            return out
        case .tiff:
            let tiff = try TIFFSignals(path: path)
            return tiff.series.indices.map { n in Result { try tiff.signal(series: n) } }
        case .mrc:
            return [.success(try MRCReader(path: path).signal)]
        case .msa:
            let s = try MSAReader.read(path: path).signal
            return [.success(FormatoLazySignal(title: s.title, signalType: s.signalType, axes: s.axes, metadata: s.metadata, array: FormatoInMemoryArray(s.data)))]
        case .empad:
            throw FormatoLoadError.useDedicatedReader(.empad, "\(name) is an EMPAD file: open it with EMPADReader (a 4D datacube, with its calibration options).")
        case .merlinMIB:
            throw FormatoLoadError.useDedicatedReader(.merlinMIB, "\(name) is a Merlin MIB file: open it with MIBReader (a 4D datacube, with its scan-shape options).")
        case .hdf5:
            throw FormatoLoadError.useDedicatedReader(.hdf5, "\(name) is an HDF5 file that is not a Velox file: HDF5Datacube reads py4DSTEM 4D datacubes; HSPY and NCEM EMD are not read.")
        case .unknown:
            throw FormatoLoadError.unknownFormat(name)
        }
    }
}
