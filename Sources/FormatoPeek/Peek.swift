//
//  Peek.swift
//  Role: what a file looks like and says, read without reading the file: one decimated frame for a thumbnail and the header facts
//        for a preview card (Quick Look and Finder-style consumers, which run in a sandboxed process with seconds and tens of MB).
//        Never more than one frame: a stack or a 4D cube is entered at its centre, an image is read at most one row at a time,
//        every `stride`-th row, and the columns are decimated in memory. Pure Swift, no UI; the pixels are the file's own (point
//        sampled, never averaged: averaging needs every pixel), so there is no Python reference for them, only a planted-gradient
//        test; the dimensions, axes and acquisition fields are the readers' (exact, see docs/parity.md).
//

import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoHDF5
import FormatoMRC
import FormatoMSA
import FormatoTIFF
import Formato

public nonisolated enum Peek {
    /// What the frame is, so a consumer picks the stretch: images percentile-stretched, patterns in log scale.
    public enum Kind: String, Sendable, Equatable {
        /// A micrograph or a survey (HAADF) image.
        case image
        /// One diffraction pattern, at the centre scan position of a 4D cube.
        case diffractionPattern
        /// A virtual image (bright or dark field) stored in a 4D file.
        case virtualImage
        /// A one-dimensional spectrum, `height` 1, binned to the largest value of each bin so peaks survive.
        case spectrum
    }

    /// One decimated frame: `pixels[row * width + column]` is source pixel `(row * stride, column * stride)`.
    public struct Frame: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let pixels: [Float]
        /// The frame this was cut from, in pixels, and the step between the source pixels it kept.
        public let sourceWidth: Int
        public let sourceHeight: Int
        public let stride: Int
        public let kind: Kind
        /// For a stack or a 4D cube: the index of the frame (or scan position) the peek entered at, slowest axis first.
        public let enteredAt: [Int]
        /// Where in the file it came from, in words ("ImageList.2", "/4DSTEM/data/datacubes/datacube_0/data").
        public let source: String

        public init(width: Int, height: Int, pixels: [Float], sourceWidth: Int, sourceHeight: Int, stride: Int, kind: Kind,
                    enteredAt: [Int], source: String) {
            self.width = width; self.height = height; self.pixels = pixels; self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight; self.stride = stride; self.kind = kind; self.enteredAt = enteredAt; self.source = source
        }
    }

    /// The facts of a file a preview card shows. Everything optional is nil when the file does not say.
    public struct Summary: Sendable, Equatable {
        public var format: String
        public var title: String?
        public var signalType: String?
        /// The previewed frame's size in pixels (a diffraction pattern's detector size for a 4D file).
        public var width: Int
        public var height: Int
        /// The scan size in positions, for a 4D file.
        public var scanWidth: Int?
        public var scanHeight: Int?
        /// The size of one pixel and its unit, as stored (the scan pixel for a 4D file, `detectorPixelSize` the detector's).
        public var pixelSize: Double?
        public var pixelUnit: String?
        public var detectorPixelSize: Double?
        public var detectorPixelUnit: String?
        public var dataType: String?
        public var acquired: String?
        public var detector: String?
        public var instrument: String?
        public var highTensionKV: Double?
        public var cameraLengthMM: Double?
        public var magnification: Double?
        /// What the peek did not or could not read, in words.
        public var notes: [String]

        public init(format: String, title: String? = nil, signalType: String? = nil, width: Int, height: Int,
                    scanWidth: Int? = nil, scanHeight: Int? = nil, pixelSize: Double? = nil, pixelUnit: String? = nil,
                    detectorPixelSize: Double? = nil, detectorPixelUnit: String? = nil, dataType: String? = nil,
                    acquired: String? = nil, detector: String? = nil, instrument: String? = nil, highTensionKV: Double? = nil,
                    cameraLengthMM: Double? = nil, magnification: Double? = nil, notes: [String] = []) {
            self.format = format; self.title = title; self.signalType = signalType; self.width = width; self.height = height
            self.scanWidth = scanWidth; self.scanHeight = scanHeight; self.pixelSize = pixelSize; self.pixelUnit = pixelUnit
            self.detectorPixelSize = detectorPixelSize; self.detectorPixelUnit = detectorPixelUnit; self.dataType = dataType
            self.acquired = acquired; self.detector = detector; self.instrument = instrument; self.highTensionKV = highTensionKV
            self.cameraLengthMM = cameraLengthMM; self.magnification = magnification; self.notes = notes
        }
    }

    public enum PeekError: Error, Equatable, LocalizedError {
        case unsupported(String)
        public var errorDescription: String? { if case .unsupported(let s) = self { return s }; return nil }
    }

    /// The largest `maxPixels` honoured (a frame is at most this many pixels on a side).
    public static let maximumSide = 2048

    // MARK: Thumbnail

    /// One frame of `url`, at most `maxPixels` on its longer side. Reads one row at a time; never the whole dataset.
    public static func thumbnailFrame(url: URL, maxPixels: Int) throws -> Frame {
        let limit = min(max(maxPixels, 1), maximumSide)
        let path = url.path
        switch FormatoLoader.sniff(path: path) {
        case .digitalMicrograph:
            let dm = try DMFile(path: path)
            let (object, signal) = try dmImage(dm)
            if signal.array.shape.count == 1 { return try spectrum(signal.array, limit: limit, source: "ImageList.\(object.index)") }
            return try frame(of: signal.array, limit: limit, kind: .image, source: "ImageList.\(object.index)")
        case .veloxEMD:
            let images = try VeloxImageSignals(path: path)
            guard let entry = VeloxImageSelection.choose(images.images) else {
                throw PeekError.unsupported("This Velox file holds no image, only spectra.")
            }
            return try frame(of: try images.signal(entry).array, limit: limit, kind: .image, source: "Data/Image/\(entry.id)")
        case .tiff:
            let tiff = try TIFFSignals(path: path)
            guard let n = tiff.series.firstIndex(where: { $0.axes.hasSuffix("YX") }) else {
                throw PeekError.unsupported("This TIFF holds no greyscale image series.")
            }
            return try frame(of: try tiff.signal(series: n).array, limit: limit, kind: .image, source: "series \(n)")
        case .mrc:
            return try frame(of: try MRCReader(path: path).signal.array, limit: limit, kind: .image, source: "MRC data")
        case .msa:
            let s = try MSAReader.read(path: path).signal
            return try spectrum(FormatoInMemoryArray(s.data), limit: limit, source: "MSA spectrum")
        case .hdf5:
            let found = try py4DSTEMLayout(path: path)
            if let image = found.virtualImagePath {
                let array = try StoredPlane(path: path, datasetPath: image)
                return try frame(of: array, limit: limit, kind: .virtualImage, source: image)
            }
            return try frame(of: found.cube, limit: limit, kind: .diffractionPattern, source: found.cube.datasetPath)
        case .empad, .merlinMIB:
            throw PeekError.unsupported("Raw 4D files (EMPAD, MIB) have no stored image to peek at.")
        case .unknown:
            throw PeekError.unsupported("\(url.lastPathComponent) is not a format FormatoKit reads.")
        }
    }

    // MARK: Summary

    /// The header facts of `url`, from the headers and tag directories only.
    public static func summary(url: URL) throws -> Summary {
        let path = url.path
        switch FormatoLoader.sniff(path: path) {
        case .digitalMicrograph:
            let dm = try DMFile(path: path)
            let (object, signal) = try dmImage(dm)
            var s = base("Gatan DigitalMicrograph", signal)
            s.title = object.name
            fill(&s, from: AcquisitionMetadata.dm(object))
            return s
        case .veloxEMD:
            let images = try VeloxImageSignals(path: path)
            guard let entry = VeloxImageSelection.choose(images.images) else {
                throw PeekError.unsupported("This Velox file holds no image, only spectra.")
            }
            let signal = try images.signal(entry)
            var s = base("Velox EMD", signal)
            fill(&s, from: AcquisitionMetadata.velox(entry))
            if s.detector == nil, !entry.detectorName.isEmpty { s.detector = entry.detectorName }
            return s
        case .tiff:
            let tiff = try TIFFSignals(path: path)
            guard let n = tiff.series.firstIndex(where: { $0.axes.hasSuffix("YX") }) else {
                throw PeekError.unsupported("This TIFF holds no greyscale image series.")
            }
            var s = base("TIFF", try tiff.signal(series: n))
            if let a = try? AcquisitionMetadata.tiff(path: path) { fill(&s, from: a) }
            return s
        case .mrc:
            var s = base("MRC", try MRCReader(path: path).signal)
            if let a = try? AcquisitionMetadata.mrc(path: path) { fill(&s, from: a) }
            return s
        case .msa:
            let spectrum = try MSAReader.read(path: path)
            var s = base("EMSA/MSA spectrum", FormatoLazySignal(
                title: spectrum.signal.title, signalType: spectrum.signal.signalType, axes: spectrum.signal.axes,
                metadata: spectrum.signal.metadata, array: FormatoInMemoryArray(spectrum.signal.data)))
            s.height = 1
            return s
        case .hdf5:
            let found = try py4DSTEMLayout(path: path)
            let cube = found.cube
            let scanAxis = cube.axes.first, detectorAxis = cube.axes.count > 2 ? cube.axes[2] : nil
            var s = Summary(format: "py4DSTEM HDF5", title: nil, signalType: "electron_diffraction", width: cube.shape[3], height: cube.shape[2],
                            scanWidth: cube.shape[1], scanHeight: cube.shape[0], pixelSize: scanAxis?.scale, pixelUnit: scanAxis?.units,
                            detectorPixelSize: detectorAxis?.scale, detectorPixelUnit: detectorAxis?.units,
                            dataType: cube.dataType.rawValue, notes: [])
            if found.virtualImagePath != nil {
                // The previewed frame is the stored virtual image, one pixel per scan position.
                s.width = cube.shape[1]; s.height = cube.shape[0]
                s.notes.append("a stored virtual image is previewed")
            }
            return s
        case .empad, .merlinMIB:
            throw PeekError.unsupported("Raw 4D files (EMPAD, MIB) have no stored image to peek at.")
        case .unknown:
            throw PeekError.unsupported("\(url.lastPathComponent) is not a format FormatoKit reads.")
        }
    }

    // MARK: Pieces

    private static func base(_ format: String, _ signal: FormatoLazySignal) -> Summary {
        let shape = signal.array.shape
        let rows = shape.count >= 2 ? shape[shape.count - 2] : 1
        let cols = shape.last ?? 1
        let axis = signal.axes.count >= 1 ? signal.axes[signal.axes.count - 1] : nil
        var summary = Summary(format: format, title: signal.title.isEmpty ? nil : signal.title,
                              signalType: signal.signalType.isEmpty ? nil : signal.signalType, width: cols, height: rows,
                              pixelSize: axis?.scale, pixelUnit: axis?.units, dataType: signal.array.dataType.rawValue, notes: [])
        // The reader's own mapping of the beam energy, for files whose acquisition fields name no voltage.
        summary.highTensionKV = signal.metadata["Acquisition_instrument.TEM.beam_energy"]?.value.number
        return summary
    }

    private static func fill(_ s: inout Summary, from a: AcquisitionMetadata) {
        s.acquired = a.acquired?.value
        s.detector = a.detector?.value
        s.instrument = a.instrument?.value
        s.highTensionKV = a.highTensionKV?.value ?? s.highTensionKV
        s.cameraLengthMM = a.cameraLengthMM?.value
        s.magnification = a.magnification?.value
    }

    /// The image GMS shows first: the first non-thumbnail object of two dimensions, else of more (a stack or a spectrum image is
    /// entered at its centre), else a spectrum. Objects of a type FormatoKit does not read are skipped.
    private static func dmImage(_ dm: DMFile) throws -> (DM4ImageObject, FormatoLazySignal) {
        let readable = dm.objects.compactMap { object -> (DM4ImageObject, FormatoLazySignal)? in
            guard let signal = try? dm.signal(index: object.index) else { return nil }
            return (object, signal)
        }
        // A spectrum image (EELS / EDS, energy last) is not an image stack: its centre slice would be a stripe, so it is skipped.
        func isSpectrumImage(_ signal: FormatoLazySignal) -> Bool { signal.array.shape.count == 3 && signal.signalType.hasPrefix("E") }
        for rank in [2, 3, 4, 1] {
            if let hit = readable.first(where: { $0.1.array.shape.count == rank && !isSpectrumImage($0.1) }) { return hit }
        }
        throw PeekError.unsupported("\(formatoDisplayFileName(dm.path)) holds no image FormatoKit reads.")
    }

    /// The layout of a py4DSTEM-style HDF5: its 4D cube (the canonical paths first, then any numeric rank-4 dataset) and a stored
    /// virtual image beside it (a rank-2 dataset of the scan's shape whose path says "virtual", "haadf" or "survey").
    private static func py4DSTEMLayout(path: String) throws -> (cube: HDF5Datacube, virtualImagePath: String?) {
        let reader = try HDF5Reader(url: URL(fileURLWithPath: path))
        let canonical = ["/4DSTEM_experiment/data/datacubes/datacube_0/data", "/4DSTEM/data/datacubes/datacube_root/data",
                         "/datacube_root/datacube/data"]
        var datasets: [String] = []
        for p in try reader.descendants() where p.kind == .dataset { datasets.append(p.path) }
        var rank4: [String] = []
        var rank2: [(String, [Int])] = []
        for d in datasets {
            guard let info = try? reader.datasetInfo(d), case .numeric = info.type else { continue }
            if info.shape.count == 4 { rank4.append(d) } else if info.shape.count == 2 { rank2.append((d, info.shape)) }
        }
        let ordered = canonical.filter(rank4.contains) + rank4.filter { !canonical.contains($0) }
        for candidate in ordered {
            guard let cube = try? HDF5Datacube(path: path, datasetPath: candidate) else { continue }
            let scan = Array(cube.shape.prefix(2))
            let virtual = rank2.first { entry in
                entry.1 == scan && ["virtual", "haadf", "survey"].contains { entry.0.lowercased().contains($0) }
            }?.0
            return (cube, virtual)
        }
        throw PeekError.unsupported("This HDF5 file holds no 4D datacube.")
    }

    /// One frame of a lazy array of rank ≥ 2: its last two dimensions, entered at the centre of the others.
    private static func frame(of array: any FormatoLazyArray, limit: Int, kind: Kind, source: String) throws -> Frame {
        let shape = array.shape
        guard shape.count >= 2 else { throw PeekError.unsupported("The data has fewer than two dimensions.") }
        guard array.dataType.components == 1 else { throw PeekError.unsupported("Colour images are not previewed.") }
        let rows = shape[shape.count - 2], cols = shape[shape.count - 1]
        guard rows > 0, cols > 0 else { throw PeekError.unsupported("The image is empty.") }
        let lead = shape.dropLast(2).map { $0 / 2 }
        let stride = Swift.max(1, (Swift.max(rows, cols) + limit - 1) / limit)
        let outRows = (rows + stride - 1) / stride, outCols = (cols + stride - 1) / stride
        var pixels = [Float](repeating: 0, count: outRows * outCols)
        let leadCount = [Int](repeating: 1, count: lead.count)
        // A row is read in chunks of at most `chunk` columns (a multiple of the stride), so a very wide image costs a few MB.
        let chunk = Swift.max(stride, (1 << 20) / stride * stride)
        for i in 0..<outRows {
            var c0 = 0
            while c0 < cols {
                let n = Swift.min(chunk, cols - c0)
                let part = try array.read(start: lead + [i * stride, c0], count: leadCount + [1, n]).doubles()
                for j in 0..<((n + stride - 1) / stride) { pixels[i * outCols + (c0 / stride) + j] = Float(part[j * stride]) }
                c0 += n
            }
        }
        return Frame(width: outCols, height: outRows, pixels: pixels, sourceWidth: cols, sourceHeight: rows, stride: stride,
                     kind: kind, enteredAt: lead, source: source)
    }

    /// A one-dimensional array as a spectrum frame: at most `limit` bins, each the largest value of its samples (NaN ignored),
    /// read in chunks so a very long spectrum costs O(limit) memory. `stride` is the samples per bin, rounded up.
    private static func spectrum(_ array: any FormatoLazyArray, limit: Int, source: String) throws -> Frame {
        guard array.shape.count == 1, array.shape[0] > 0 else { throw PeekError.unsupported("This is not a one-dimensional spectrum.") }
        let n = array.shape[0]
        let bins = Swift.min(n, limit)
        var out = [Float](repeating: -.infinity, count: bins)
        var seen = [Bool](repeating: false, count: bins)
        let chunk = 1 << 20
        var k = 0
        while k < n {
            let m = Swift.min(chunk, n - k)
            let part = try array.read(start: [k], count: [m]).doubles()
            for (i, v) in part.enumerated() where !v.isNaN {
                let bin = Swift.min(bins - 1, (k + i) * bins / n)
                out[bin] = Swift.max(out[bin], Float(v)); seen[bin] = true
            }
            k += m
        }
        for b in 0..<bins where !seen[b] { out[b] = 0 }
        return Frame(width: bins, height: 1, pixels: out, sourceWidth: n, sourceHeight: 1, stride: (n + bins - 1) / bins, kind: .spectrum,
                     enteredAt: [], source: source)
    }
}

/// A rank-2 stored dataset (a virtual image kept in a 4D file) as a lazy array.
private nonisolated struct StoredPlane: FormatoLazyArray {
    let reader: HDF5Reader
    let datasetPath: String
    let shape: [Int]
    let dataType: FormatoDataType
    init(path: String, datasetPath: String) throws {
        let reader = try HDF5Reader(url: URL(fileURLWithPath: path))
        let info = try reader.datasetInfo(datasetPath)
        guard info.shape.count == 2, case .numeric(let type) = info.type else {
            throw Peek.PeekError.unsupported("\(datasetPath) is not a numeric image.")
        }
        self.reader = reader; self.datasetPath = datasetPath; shape = info.shape; dataType = type
    }
    func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        return try reader.readDataset(datasetPath, start: start, count: count)
    }
}
