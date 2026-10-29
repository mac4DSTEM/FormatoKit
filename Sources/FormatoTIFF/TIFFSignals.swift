//
//  TIFFSignals.swift
//  Role: a TIFF file as FormatoCore signals, the way RosettaSciIO 049e7d70's `rsciio.tiff.file_reader` returns them with its
//        defaults, over the parts of tifffile 2026.9.20 it relies on: the series (ImageJ,
//        else uniform or generic grouping), the FEI INI tags, the ImageJ description, the Gatan DM tags. Data as stored;
//        RGB as one element per pixel. Out of step 2, refused by name: Zeiss SEM, TVIPS, Olympus SIS, JEOL SightX,
//        Hamamatsu streak (unless `TIFFReadOptions.vendorBranches` is `.readAsGeneric`), compressed or tiled pages.
//

import Foundation
import FormatoCore

/// One page's pixel layout (step 2 §3.2): uncompressed strips, contiguous samples.
public nonisolated struct TIFFPageLayout: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let dataType: FormatoDataType
    /// Samples per pixel as stored (1, 3 or 4).
    public let samples: Int
    let bytesPerSample: Int
    let stripOffsets: [Int]
    let stripByteCounts: [Int]
    let rowsPerStrip: Int
    let bigEndian: Bool
    let photometric: Int64
    let extraSamples: [Int64]
    /// tifffile's `TiffPage.is_contiguous` (and `is_final`, as fill order and predictor are refused): the page's strips follow
    /// each other in the file.
    var isContiguous: Bool {
        if stripOffsets.count == 1 { return true }
        // Overflow-reporting arithmetic: a planted count near 2^62 is not contiguous, and neither is a negative or oversized count.
        let page = pageBytes
        var total = 0
        for count in stripByteCounts {
            guard count >= 0 && count <= page else { return false }
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return false }
            total = sum
        }
        guard total == page else { return false }
        for i in 0..<(stripOffsets.count - 1) {
            let (end, overflow) = stripOffsets[i].addingReportingOverflow(stripByteCounts[i])
            guard !overflow, stripByteCounts[i] != 0, end == stripOffsets[i + 1] else { return false }
        }
        return true
    }
    /// Bytes of one row, all samples.
    var rowBytes: Int { width * samples * bytesPerSample }
    var pageBytes: Int { rowBytes * height }

    /// The layout of `dir`, or the reason it is refused.
    public static func of(_ dir: TIFFDirectory, bigEndian: Bool, fileSize: Int) throws -> TIFFPageLayout {
        func int(_ code: Int, _ fallback: Int64? = nil) -> Int64? { dir[code]?.integer ?? fallback }
        guard let w = int(256), let h = int(257), w > 0, h > 0, w < 1 << 31, h < 1 << 31 else {
            throw TIFFError.unsupportedLayout("The page has no image width or height.")
        }
        let compression = int(259, 1) ?? 1
        guard compression == 1 else { throw TIFFError.unsupportedLayout("The page is compressed (Compression \(compression)); only uncompressed TIFF is read.") }
        if dir[322] != nil || dir[324] != nil { throw TIFFError.unsupportedLayout("The page is tiled; only strips are read.") }
        let samples = Int(int(277, 1) ?? 1)
        let planar = int(284, 1) ?? 1
        guard planar == 1 || samples == 1 else { throw TIFFError.unsupportedLayout("The page stores its samples in separate planes (PlanarConfiguration 2).") }
        let bits = dir[258]?.integers ?? [1]
        let formats = dir[339]?.integers ?? [1]
        guard let b = bits.first, bits.allSatisfy({ $0 == b }), let f = formats.first, formats.allSatisfy({ $0 == f }) else {
            throw TIFFError.unsupportedLayout("The page mixes sample sizes or formats.")
        }
        // RosettaSciIO logs `op["PhotometricInterpretation"]` and raises without it; tifffile reads FillOrder 2 bit-reversed and
        // undoes a predictor; ImageDepth makes a volume page. Refused rather than ported.
        guard let photometric = int(262) else { throw TIFFError.unsupportedLayout("The page has no PhotometricInterpretation.") }
        if let fill = int(266), fill != 1 { throw TIFFError.unsupportedLayout("The page sets FillOrder \(fill).") }
        if let predictor = int(317), predictor != 1 { throw TIFFError.unsupportedLayout("The page sets Predictor \(predictor).") }
        if let depth = int(32997), depth != 1 { throw TIFFError.unsupportedLayout("The page sets ImageDepth \(depth) (an SGI volume).") }
        guard (samples == 1 && [0, 1, 3].contains(photometric)) || (samples > 1 && photometric == 2) else {
            throw TIFFError.unsupportedLayout("The page holds \(samples) sample(s) with PhotometricInterpretation \(photometric).")
        }
        let type: FormatoDataType
        switch (samples, photometric, f, b) {
        case (1, _, 1, 8): type = .uint8
        case (1, _, 1, 16): type = .uint16
        case (1, _, 1, 32): type = .uint32
        case (1, _, 1, 64): type = .uint64
        case (1, _, 2, 8): type = .int8
        case (1, _, 2, 16): type = .int16
        case (1, _, 2, 32): type = .int32
        case (1, _, 2, 64): type = .int64
        case (1, _, 3, 32): type = .float32
        case (1, _, 3, 64): type = .float64
        case (3, 2, 1, 8): type = .rgb8
        case (4, 2, 1, 8): type = .rgba8
        case (3, 2, 1, 16): type = .rgb16
        case (4, 2, 1, 16): type = .rgba16
        default: throw TIFFError.unsupportedLayout("The page holds \(samples) sample(s) of \(b) bits, format \(f), photometric \(photometric), which this reader does not read.")
        }
        guard let offsets = dir[273]?.integers, let counts = dir[279]?.integers, offsets.count == counts.count, !offsets.isEmpty else {
            throw TIFFError.unsupportedLayout("The page has no strips.")
        }
        let rps = Int(min(int(278, 0xFFFF_FFFF) ?? 0xFFFF_FFFF, h))
        // Sizes without overflow: a row and a page must be addressable.
        let (rowBytes, o1) = Int(w).multipliedReportingOverflow(by: samples * (Int(b) / 8))
        let (pageBytes, o2) = rowBytes.multipliedReportingOverflow(by: Int(h))
        guard !o1, !o2, pageBytes <= fileSize else { throw TIFFError.truncated("The page claims more bytes than the file holds.") }
        // tifffile treats a strip offset of 0 as a missing strip: refused.
        guard !offsets.contains(0) else { throw TIFFError.unsupportedLayout("A strip offset of the page is 0 (a missing strip).") }
        let layout = TIFFPageLayout(width: Int(w), height: Int(h), dataType: type, samples: samples, bytesPerSample: Int(b) / 8,
                                    stripOffsets: offsets.map(Int.init), stripByteCounts: counts.map(Int.init),
                                    rowsPerStrip: max(rps, 1), bigEndian: bigEndian, photometric: photometric,
                                    extraSamples: dir[338]?.integers ?? [])
        // Every row must lie inside its strip and the strip inside the file.
        let strips = (layout.height + layout.rowsPerStrip - 1) / layout.rowsPerStrip
        guard strips <= offsets.count else { throw TIFFError.truncated("The page has fewer strips than rows need.") }
        for s in 0..<strips {
            let rows = min(layout.rowsPerStrip, layout.height - s * layout.rowsPerStrip)
            let need = rows * layout.rowBytes
            guard layout.stripByteCounts[s] >= need, layout.stripOffsets[s] >= 0, layout.stripOffsets[s] <= fileSize - need else {
                throw TIFFError.truncated("A strip of the page lies outside the file or is shorter than its rows.")
            }
        }
        return layout
    }

    /// The file offset of row `y`.
    func rowOffset(_ y: Int) -> Int {
        stripOffsets[y / rowsPerStrip] + (y % rowsPerStrip) * rowBytes
    }

    /// Converts stored bytes of whole elements to little-endian in place.
    func toLittleEndian(_ data: inout Data) {
        guard bigEndian, bytesPerSample > 1 else { return }
        data.withUnsafeMutableBytes { p in
            var i = 0
            while i + bytesPerSample <= p.count {
                for k in 0..<(bytesPerSample / 2) { p.swapAt(i + k, i + bytesPerSample - 1 - k) }
                i += bytesPerSample
            }
        }
    }
}

/// One image source of a series: a page, or, for an ImageJ file whose images follow the first page contiguously, a
/// virtual page `index` of it.
nonisolated struct TIFFImageSource: Sendable {
    let layout: TIFFPageLayout
    /// Added to every row offset (a virtual ImageJ image: index × page bytes).
    let shift: Int
}

/// A series as tifffile builds it (the subset in scope): its axes codes and the images it reads, in order.
public nonisolated struct TIFFSeries: Sendable {
    /// tifffile's axes codes after its squeeze ("YX", "IYX", "ZYX", "YXS", ...).
    public let axes: String
    public let shape: [Int]
    public let dataType: FormatoDataType
    /// The real pages, or (an ImageJ virtual stack) one page whose `virtualCount` images follow its data contiguously:
    /// computed per image, never one record per image.
    let pages: [TIFFPageLayout]
    let virtualCount: Int?
    /// The index of the directory the series starts at (its first page, whose tags give the metadata).
    let firstDirectory: Int

    init(axes: String, shape: [Int], dataType: FormatoDataType, pages: [TIFFPageLayout], virtualCount: Int? = nil, firstDirectory: Int = 0) {
        self.axes = axes; self.shape = shape; self.dataType = dataType; self.pages = pages; self.virtualCount = virtualCount
        self.firstDirectory = firstDirectory
    }

    func source(_ i: Int) -> TIFFImageSource {
        if virtualCount != nil { return TIFFImageSource(layout: pages[0], shift: i * pages[0].pageBytes) }
        return TIFFImageSource(layout: pages[i], shift: 0)
    }
}

public nonisolated struct TIFFSignals: Sendable {
    public let file: TIFFFile
    public let series: [TIFFSeries]

    /// The vendor branch this file was read as a plain TIFF for (`TIFFReadOptions.vendorBranches == .readAsGeneric`), or nil:
    /// nil for every file read by default and for a file that carries no vendor branch's tags.
    public let vendorBranch: String?

    let veloxCalibration: Bool

    /// Reads the file with the default options: a vendor branch that is not ported is refused by name.
    public init(path: String) throws {
        try self.init(path: path, options: TIFFReadOptions())
    }

    /// Reads the file under `options`. Layout refusals (compression, tiles, unsupported sample layouts) hold under every
    /// option.
    public init(path: String, options: TIFFReadOptions) throws {
        let file = try TIFFFile(path: path)
        guard let first = file.directories.first else { throw TIFFError.notTIFF(formatoDisplayFileName(path)) }
        self.file = file
        var branch: String?
        if let refusal = Self.outOfScope(first) {
            switch options.vendorBranches {
            case .refuse:
                throw FormatoReadError.unsupported("\(formatoDisplayFileName(path)) is a \(refusal) TIFF, whose reading is not ported yet.")
            case .readAsGeneric:
                branch = refusal
            }
        }
        vendorBranch = branch
        veloxCalibration = options.veloxCalibration
        series = try Self.buildSeries(file)
    }

    /// The RosettaSciIO branch a file belongs to that step 2 does not port, or nil.
    static func outOfScope(_ page: TIFFDirectory) -> String? {
        if page[34680] != nil || page[34682] != nil { return nil }            // FEI comes first in RosettaSciIO's order
        if page[34118] != nil { return "Zeiss SEM" }
        if page[37706] != nil { return "TVIPS" }
        if page[33560] != nil || page[33471] != nil { return "Olympus SIS" }
        if page[271]?.text == "JEOL Ltd." { return "JEOL SightX" }
        if let artist = page[315]?.text, artist.hasPrefix("Copyright Hamamatsu"),
           let software = page[305]?.text, software.hasPrefix("HPD-TA") { return "Hamamatsu streak" }
        return nil
    }

    // MARK: Series

    static func imageJDescription(_ page: TIFFDirectory) -> [String: FormatoPythonValue]? {
        guard let d = page[270]?.text, d.hasPrefix("ImageJ=") || d.hasPrefix("SCIFIO=") else { return nil }
        // `imagej_description_metadata`: key=value lines; int, float, bool ("true"/"false" exactly, any case), else string.
        var out: [String: FormatoPythonValue] = [:]
        for line in TIFFFile.splitLines(d) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let i = formatoPythonInt(val) { out[key] = .int(i) }
            else if let f = formatoPythonFloat(val) { out[key] = .float(f) }
            else if val.lowercased() == "true" { out[key] = .bool(true) }
            else if val.lowercased() == "false" { out[key] = .bool(false) }
            else { out[key] = .string(val) }
        }
        return out["ImageJ"] != nil || out["SCIFIO"] != nil ? out : nil
    }

    static func buildSeries(_ file: TIFFFile) throws -> [TIFFSeries] {
        let size = file.data.count
        let first = file.directories[0]
        let layout0 = try TIFFPageLayout.of(first, bigEndian: file.bigEndian, fileSize: size)
        let pageAxes = layout0.samples > 1 ? "YXS" : "YX"
        let pageShape = layout0.samples > 1 ? [layout0.height, layout0.width, layout0.samples] : [layout0.height, layout0.width]

        // tifffile tries its own shaped series first; when the first page is shaped and that rule gives no series, the generic
        // rule follows (not ImageJ). OME series come next; not ported.
        let shaped = shapedDescription(first) != nil
        if shaped, let s = try shapedSeries(file) { return s }
        if !shaped {
            if let d = first[270]?.text, d.contains("<OME") { throw FormatoReadError.unsupported("The file is an OME-TIFF; its series rule is not ported.") }
            if let meta = imageJDescription(first), let s = try imageJSeries(file, meta, layout0, pageAxes, pageShape) {
                return [s]
            }
        }
        let layouts = try file.directories.map { try TIFFPageLayout.of($0, bigEndian: file.bigEndian, fileSize: size) }
        // Uniform or generic: pages with the same shape and type form one series, in first-seen order.
        var groups: [(key: String, pages: [TIFFPageLayout])] = []
        for l in layouts {
            let key = "\(l.width)x\(l.height)x\(l.samples) \(l.dataType) rps \(l.rowsPerStrip) photometric \(l.photometric) extra \(l.extraSamples)"
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].pages.append(l) } else { groups.append((key, [l])) }
        }
        // tifffile splits pages by more than shape and type, and merges reduced-size pages into pyramids: a file whose pages
        // fall in more than one group is refused rather than guessed.
        guard groups.count == 1 else {
            throw FormatoReadError.unsupported("The file's pages form \(groups.count) groups; several series are not ported.")
        }
        return groups.map { g in
            let n = g.pages.count, l = g.pages[0]
            let axes = (n > 1 ? "I" : "") + (l.samples > 1 ? "YXS" : "YX")
            let shape: [Int] = (n > 1 ? [n] : [Int]()) + (l.samples > 1 ? [l.height, l.width, l.samples] : [l.height, l.width])
            return TIFFSeries(axes: axes, shape: shape, dataType: l.dataType, pages: g.pages)
        }
    }

    /// tifffile's `series_imagej` for the files in scope; nil where it returns None (then the generic rule applies). A
    /// description whose counts are not integers, a count overflow, pages that disagree with the first, or images that
    /// neither the pages nor a contiguous block after the first page hold, are refused.
    static func imageJSeries(_ file: TIFFFile, _ meta: [String: FormatoPythonValue], _ page: TIFFPageLayout,
                             _ pageAxes: String, _ pageShape: [Int]) throws -> TIFFSeries? {
        func int(_ k: String) throws -> Int {
            switch meta[k] {
            case nil: return 1
            case .int(let i)?: guard let v = Int(exactly: i) else { fallthrough }; return v
            default: throw FormatoReadError.unsupported("The ImageJ description's '\(k)' is not an integer this reader takes.")
            }
        }
        let frames = try int("frames"), slices = try int("slices")
        var channels = try int("channels"), images = try int("images")
        guard images >= 1, frames >= 1, slices >= 1, channels >= 1 else { return nil }
        func mul(_ a: Int, _ b: Int) throws -> Int {
            let (r, o) = a.multipliedReportingOverflow(by: b)
            guard !o else { throw FormatoReadError.unsupported("The ImageJ description's counts overflow.") }
            return r
        }
        if channels == 1 {
            images = try mul(frames, slices)
        } else if images == (try mul(frames, slices)) && page.samples == channels {
            channels = 1
        } else {
            images = try mul(try mul(frames, slices), channels)
        }
        let pages = file.directories.count
        if images == 1 && pages > 1 { images = pages }
        let nbytes = try mul(images, page.pageBytes)
        guard page.stripOffsets[0] <= file.data.count - nbytes else { return nil }   // "metadata invalid or corrupted": None
        let order: String
        switch meta["order"] { case .string(let s)?: order = s.lowercased(); default: order = "czt" }
        var axes: [Character], shape: [Int]
        switch order {
        case "ctz": axes = ["Z", "T", "C"]; shape = [slices, frames, channels]
        case "zct": axes = ["T", "C", "Z"]; shape = [frames, channels, slices]
        case "ztc": axes = ["C", "T", "Z"]; shape = [channels, frames, slices]
        case "tcz": axes = ["Z", "C", "T"]; shape = [slices, channels, frames]
        case "tzc": axes = ["C", "Z", "T"]; shape = [channels, slices, frames]
        default: axes = ["T", "Z", "C"]; shape = [frames, slices, channels]
        }
        let remain = images / (try mul(try mul(shape[0], shape[1]), shape[2]))
        if remain > 1 { axes.insert("I", at: 0); shape.insert(remain, at: 0) }
        axes += Array(pageAxes); shape += pageShape
        // tifffile's squeeze: length-1 axes go, Y and X stay.
        var sq: [(Character, Int)] = []
        for (a, n) in zip(axes, shape) where n > 1 || a == "Y" || a == "X" { sq.append((a, n)) }
        // tifffile: virtual when there is one page, or when page 0's data ends before page 1 starts.
        let layouts: [TIFFPageLayout]
        var virtual: Int?
        if pages == 1 || page.stripOffsets[0] + nbytes <= file.directories[1].offset {
            let contiguous = zip(page.stripOffsets, page.stripOffsets.dropFirst()).allSatisfy { $1 - $0 == page.rowsPerStrip * page.rowBytes }
            guard contiguous else { throw FormatoReadError.unsupported("An ImageJ virtual stack whose first page's strips are not contiguous.") }
            layouts = [page]; virtual = images
        } else {
            guard pages >= images else { throw FormatoReadError.unsupported("The ImageJ description counts \(images) images over \(pages) pages.") }
            layouts = try file.directories.prefix(images).map {
                let l = try TIFFPageLayout.of($0, bigEndian: file.bigEndian, fileSize: file.data.count)
                guard l.width == page.width, l.height == page.height, l.dataType == page.dataType else {
                    throw FormatoReadError.unsupported("A page of the ImageJ stack differs from the first.")
                }
                return l
            }
        }
        return TIFFSeries(axes: String(sq.map(\.0)), shape: sq.map(\.1), dataType: page.dataType, pages: layouts, virtualCount: virtual)
    }

    // MARK: Signals

    /// The lazy signal of series `index`: RosettaSciIO's axes and metadata for it.
    public func signal(series index: Int) throws -> FormatoLazySignal {
        guard series.indices.contains(index) else { throw FormatoReadError.unsupported("No series \(index).") }
        let s = series[index]
        let page = file.directories[s.firstDirectory]
        let name = formatoDisplayFileName(file.path)
        // RosettaSciIO drops the sample axis of an RGB page (a structured element per pixel).
        let isRGB = s.dataType.components > 1
        if isRGB, s.shape.last != s.dataType.components {
            throw FormatoReadError.unsupported("The series' last dimension is not the page's \(s.dataType.components) samples; RosettaSciIO raises on it.")
        }
        let codes = Array(isRGB ? String(s.axes.dropLast()) : s.axes)
        let shape = isRGB ? Array(s.shape.dropLast()) : s.shape
        // `axes_label_codes[axis]`: a code it does not list (a user's `axes` in a shaped description) is a KeyError.
        guard codes.allSatisfy({ Self.axisCodes.contains($0) }) else {
            throw FormatoReadError.unsupported("The series' axes \(s.axes) hold a code RosettaSciIO has no name for; it raises on it.")
        }
        let names = codes.map(Self.axisName)
        var axes: [FormatoAxis]
        do { axes = try Self.axes(page: page, shape: shape, names: names) } catch {
            // `_read_tiff`: any exception while parsing the scale gives the default dictionaries.
            axes = Self.dictionaries(shape: shape, names: names, scales: nil, offsets: nil, units: nil)
        }
        var veloxNote: String?
        if veloxCalibration, page[34680] == nil, page[34682] == nil, let calibration = TIFFVeloxCalibration.read(page) {
            // The first consumer's option: the XML's pixel size. "width" is the columns (x), "height" the rows (y).
            switch calibration {
            case .disagree:
                axes = Self.dictionaries(shape: shape, names: names, scales: nil, offsets: nil, units: nil)
                veloxNote = TIFFVeloxCalibration.disagreeNote
            case .calibrated(let xScale, let xUnit, let yScale, let yUnit):
                func usable(_ scale: Double, _ unit: String) -> Bool { scale.isFinite && scale > 0 && !unit.isEmpty }
                var scales = [Double](repeating: 1, count: names.count)
                var units = [String?](repeating: nil, count: names.count)
                for (i, n) in names.enumerated() {
                    if n == "width", usable(xScale, xUnit) { scales[i] = xScale; units[i] = xUnit }
                    if n == "height", usable(yScale, yUnit) { scales[i] = yScale; units[i] = yUnit }
                }
                axes = Self.dictionaries(shape: shape, names: names, scales: scales, offsets: nil, units: units)
                veloxNote = TIFFVeloxCalibration.unvalidatedNote
            }
        }
        var metadata = try Self.metadata(page: page, file: name)
        if let veloxNote {
            metadata.set(FormatoMetadataEntry(
                key: "FormatoKit.policy.velox_calibration", value: .text(veloxNote), units: nil,
                provenance: FormatoProvenance(file: name, source: "tag 34683 BinaryResult/PixelSize, tags 65450-65452",
                                              rule: "FormatoKit option, not RosettaSciIO's: the first consumer's Velox pixel size")))
        }
        if let vendorBranch {
            metadata.set(FormatoMetadataEntry(
                key: "FormatoKit.policy.vendor_branch", value: .text(vendorBranch), units: nil,
                provenance: FormatoProvenance(file: name, source: "(the page's vendor tags)",
                                              rule: "FormatoKit policy, not RosettaSciIO's: read as a plain TIFF, the \(vendorBranch) branch is not ported")))
        }
        return FormatoLazySignal(title: "", signalType: "", axes: axes, metadata: metadata,
                                 array: TIFFSeriesArray(path: file.path, series: s, shape: shape))
    }

    /// The keys of RosettaSciIO's `axes_label_codes`.
    static let axisCodes: Set<Character> = ["X", "Y", "S", "P", "I", "Z", "C", "E", "T", "R", "A", "F", "H", "L", "V", "Q", "_"]

    /// RosettaSciIO's `axes_label_codes` (the names it gives tifffile's axis codes; "None" for Q and _).
    static func axisName(_ c: Character) -> String {
        switch c {
        case "X": return "width"
        case "Y": return "height"
        case "S": return "sample"
        case "P": return "plane"
        case "I": return "image series"
        case "Z": return "depth"
        case "C": return "color|em-wavelength|channel"
        case "E": return "ex-wavelength|lambda"
        case "T": return "time"
        case "R": return "region|tile"
        case "A": return "angle"
        case "F": return "phase"
        case "H": return "lifetime"
        case "L": return "exposure"
        case "V": return "event"
        default: return "None"
        }
    }

    typealias Triple = (x: Double, y: Double, z: Double)
    typealias Units = (x: String?, y: String?, z: String?)

    /// `_build_axes_dictionaries`: navigate all but the last two; units None stored as "".
    static func dictionaries(shape: [Int], names: [String], scales: [Double]?, offsets: [Double]?, units: [String?]?) -> [FormatoAxis] {
        shape.indices.map { i in
            FormatoAxis(name: names[i], size: shape[i], scale: scales?[i] ?? 1.0, offset: offsets?[i] ?? 0.0,
                        units: (units?[i] ?? nil) ?? "", navigate: i < shape.count - 2)
        }
    }

    /// `_order_axes_by_name`, its cross-over included: "height" takes the x entries, "width" the y entries.
    static func ordered(_ names: [String], _ s: Triple, _ o: Triple, _ u: Units) -> ([Double], [Double], [String?]) {
        var scales = [Double](repeating: 1.0, count: names.count), offsets = [Double](repeating: 0.0, count: names.count)
        var units = [String?](repeating: nil, count: names.count)
        for (i, n) in names.enumerated() {
            switch n {
            case "height": scales[i] = s.x; offsets[i] = o.x; units[i] = u.x
            case "width": scales[i] = s.y; offsets[i] = o.y; units[i] = u.y
            case "depth", "image series", "time": scales[i] = s.z; offsets[i] = o.z; units[i] = u.z
            default: break
            }
        }
        return (scales, offsets, units)
    }

    /// `_parse_scale_unit` for the branches in scope (FEI; the default with DM and ImageJ). Throws where RosettaSciIO's
    /// code raises (then the caller uses the default dictionaries, as `_read_tiff` does).
    static func axes(page: TIFFDirectory, shape: [Int], names: [String]) throws -> [FormatoAxis] {
        var s: Triple = (1, 1, 1), o: Triple = (0, 0, 0), u: Units = (nil, nil, nil)
        if page[34680] != nil || page[34682] != nil {
            let fei = feiMetadata(page)
            func value(_ section: String, _ key: String) throws -> FormatoPythonValue {
                guard let v = fei[section]?[key] else { throw TIFFError.unsupportedLayout("KeyError") }
                return v
            }
            func divide(_ a: Double, _ b: Double) throws -> Double {
                guard b != 0 else { throw TIFFError.unsupportedLayout("ZeroDivisionError") }   // Python float division
                return a / b
            }
            func float(_ v: FormatoPythonValue) throws -> Double {
                guard let d = v.asFloat else { throw TIFFError.unsupportedLayout("ValueError") }   // not caught by RosettaSciIO
                return d
            }
            do {
                s.x = try float(try value("Scan", "PixelWidth"))
                s.y = try float(try value("Scan", "PixelHeight"))
                u.x = "m"; u.y = "m"
            } catch TIFFError.unsupportedLayout("KeyError") {
                do {
                    s.x = try divide(try float(try value("IRBeam", "HFW")), try float(try value("Image", "ResolutionX")))
                    s.y = try divide(try float(try value("IRBeam", "VFW")), try float(try value("Image", "ResolutionY")))
                    u.x = "m"; u.y = "m"
                } catch TIFFError.unsupportedLayout("KeyError") {
                    // "Could not determine pixel size": uncalibrated, with whatever was assigned before the KeyError.
                }
            }
        } else {
            if isDigitalMicrograph(page) {
                if let v = page[65003] { u.y = dmText(v) }
                if let v = page[65004] { u.x = dmText(v) }
                if let v = page[65005] { u.z = dmText(v) }
                if let v = page[65009] { s.y = try dmNumber(v) }
                if let v = page[65010] { s.x = try dmNumber(v) }
                if let v = page[65011] { s.z = try dmNumber(v) }
                if let v = page[65006] { o.y = try dmNumber(v) }
                if let v = page[65007] { o.x = try dmNumber(v) }
                if let v = page[65008] { o.z = try dmNumber(v) }
            }
            if let meta = imageJDescription(page), meta["ImageJ"] != nil {
                if meta["unit"] != nil {
                    if meta["unit"] == .string("micron") { u.x = "µm"; u.y = "µm" }
                    let (sx, sy) = try resolutionScales(page)
                    s.x = sx; s.y = sy
                }
                if let spacing = meta["spacing"] {
                    guard let z = spacing.numberValue else { throw TIFFError.unsupportedLayout("spacing is not a number") }
                    s.z = z
                }
            }
        }
        let (scales, offsets, units) = ordered(names, s, o, u)
        return dictionaries(shape: shape, names: names, scales: scales, offsets: offsets, units: units)
    }

    /// `_get_scales_from_x_y_resolution`: (YResolution den/num, XResolution den/num).
    static func resolutionScales(_ page: TIFFDirectory) throws -> (Double, Double) {
        guard case .rationals(let y)? = page[283]?.value, let yr = y.first,
              case .rationals(let x)? = page[282]?.value, let xr = x.first else { throw TIFFError.unsupportedLayout("no resolution") }
        // Python's int / int raises ZeroDivisionError on a zero numerator.
        guard yr.numerator != 0, xr.numerator != 0 else { throw TIFFError.unsupportedLayout("ZeroDivisionError") }
        return (Double(yr.denominator) / Double(yr.numerator), Double(xr.denominator) / Double(xr.numerator))
    }

    static let dmTags = [65003, 65004, 65005, 65009, 65010, 65011, 65006, 65007, 65008, 65022, 65024, 65025]
    static func isDigitalMicrograph(_ page: TIFFDirectory) -> Bool { dmTags.contains { page[$0] != nil } }
    static func dmText(_ tag: TIFFTag) -> String? {
        if case .text(let s) = tag.value { return s }
        if tag.type == 1 || tag.type == 7 { return TIFFFile.asciiString(tag.raw) }   // BYTE / UNDEFINED text, as tifffile decodes
        return nil
    }
    static func dmNumber(_ tag: TIFFTag) throws -> Double {
        switch tag.value {
        case .reals(let v) where v.count == 1: return v[0]
        case .integers(let v) where v.count == 1: return Double(v[0])
        default: throw TIFFError.unsupportedLayout("a DM calibration tag that is not one number")
        }
    }

    /// tifffile's `fei_metadata`: the SFEG sections, then the HELIOS ones (a section replaced whole by a later one of the
    /// same name), each `read_fei_metadata`: lines stripped, `[Section]`, `key=value` at the first "=", values through
    /// `astype`.
    static func feiMetadata(_ page: TIFFDirectory) -> [String: [String: FormatoPythonValue]] {
        var result: [String: [String: FormatoPythonValue]] = [:]
        for code in [34680, 34682] {
            guard let tag = page[code] else { continue }
            var section: String?
            var parsed: [String: [String: FormatoPythonValue]] = [:]
            for raw in TIFFFile.splitLines(TIFFFile.bytes2str(tag.raw)) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    let name = String(line.dropFirst().dropLast())
                    parsed[name] = [:]; section = name
                    continue
                }
                guard let eq = line.firstIndex(of: "="), let sec = section else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                parsed[sec]?[key] = formatoPythonAsType(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            }
            for (k, v) in parsed { result[k] = v }
        }
        return result
    }

    // MARK: Metadata

    static func metadata(page: TIFFDirectory, file: String) throws -> FormatoMetadata {
        func p(_ source: String, _ rule: String) -> FormatoProvenance { FormatoProvenance(file: file, source: source, rule: rule) }
        var m = FormatoMetadata()
        m.set(FormatoMetadataEntry(key: "General.original_filename", value: .text(file), units: nil,
                                   provenance: p("(the file name)", "rsciio tiff: os.path.split(filename)[1]")))
        m.set(FormatoMetadataEntry(key: "Signal.signal_type", value: .text(""), units: nil,
                                   provenance: p("(constant)", "rsciio tiff: signal_type is \"\"")))
        // `%Y:%m:%d %H:%M:%S`; the slash form only when the page has no ImageDescription (RosettaSciIO tries the JEOL
        // description first and gives up when it is not one).
        if let dt = page[306]?.text, let (date, time) = Self.dateTime(dt, slashAllowed: page[270] == nil) {
            m.set(FormatoMetadataEntry(key: "General.date", value: .text(date), units: nil, provenance: p("tag 306 DateTime", "rsciio tiff: strptime, date().isoformat()")))
            m.set(FormatoMetadataEntry(key: "General.time", value: .text(time), units: nil, provenance: p("tag 306 DateTime", "rsciio tiff: strptime, time().isoformat()")))
        }
        if isDigitalMicrograph(page) {
            if let q = page[65022] { m.set(FormatoMetadataEntry(key: "Signal.quantity", value: .text(dmText(q) ?? ""), units: nil, provenance: p("tag 65022", "rsciio tiff: DM intensity units"))) }
            if let off = page[65024], let sc = page[65025] {
                m.set(FormatoMetadataEntry(key: "Signal.Noise_properties.Variance_linear_model.gain_factor", value: .number(try dmNumber(sc)), units: nil, provenance: p("tag 65025", "rsciio tiff: DM intensity scale")))
                m.set(FormatoMetadataEntry(key: "Signal.Noise_properties.Variance_linear_model.gain_offset", value: .number(try dmNumber(off)), units: nil, provenance: p("tag 65024", "rsciio tiff: DM intensity offset")))
            }
        }
        if page[34680] != nil || page[34682] != nil {
            try feiMapping(feiMetadata(page), into: &m, file: file)
        }
        return m
    }

    /// `datetime.strptime(value, "%Y:%m:%d %H:%M:%S")`, else `"%Y/%m/%d %H:%M"`; the ISO date and time strings, or nil
    /// when neither matches (RosettaSciIO then records no date).
    static func dateTime(_ s: String, slashAllowed: Bool = true) -> (String, String)? {
        // Python's `_strptime` patterns (ASCII digits here; Python's `\d` also takes other decimal digits, a registered
        // deviation): %Y four digits, %m 1-12, %d 1-31 (also " 5"), %H, %M, %S; whitespace in the format is `\s+`.
        let Y = "([0-9]{4})", m = "(1[0-2]|0[1-9]|[1-9])", d = "(3[01]|[12][0-9]|0[1-9]|[1-9]| [1-9])"
        let H = "(2[0-3]|[0-1][0-9]|[0-9])", M = "([0-5][0-9]|[0-9])", S = "(6[0-1]|[0-5][0-9]|[0-9])"
        func parse(_ pattern: String, _ hasSeconds: Bool) -> (String, String)? {
            guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            let g = (1..<match.numberOfRanges).map { Int(s[Range(match.range(at: $0), in: s)!].trimmingCharacters(in: .whitespaces)) ?? -1 }
            let (y, mo, day, h, mi) = (g[0], g[1], g[2], g[3], g[4]), sec = hasSeconds ? g[5] : 0
            let cal = Calendar(identifier: .gregorian)
            guard y >= 1, sec <= 59, let first = cal.date(from: DateComponents(year: y, month: mo)),
                  let days = cal.range(of: .day, in: .month, for: first), days.contains(day) else { return nil }   // datetime() raises
            return (String(format: "%04d-%02d-%02d", y, mo, day), String(format: "%02d:%02d:%02d", h, mi, sec))
        }
        if let r = parse("\(Y):\(m):\(d)\\s+\(H):\(M):\(S)", true) { return r }
        return slashAllowed ? parse("\(Y)/\(m)/\(d)\\s+\(H):\(M)", false) : nil
    }

    /// RosettaSciIO's `mapping_fei`, applied as HyperSpy applies a mapping (the value at the path, through the function;
    /// a function returning None gives no entry).
    static func feiMapping(_ fei: [String: [String: FormatoPythonValue]], into m: inout FormatoMetadata, file: String) throws {
        func put(_ key: String, _ section: String, _ field: String, _ make: (FormatoPythonValue) throws -> FormatoValue?, rule: String) rethrows {
            guard let v = fei[section]?[field], let value = try make(v) else { return }
            m.set(FormatoMetadataEntry(key: key, value: value, units: nil,
                                       provenance: FormatoProvenance(file: file, source: "fei_metadata.\(section).\(field)", rule: rule)))
        }
        func raw(_ v: FormatoPythonValue) -> FormatoValue {
            switch v { case .int(let i): return .number(Double(i)); case .float(let d): return .number(d); case .bool(let b): return .flag(b); case .string(let s): return .text(s) }
        }
        func scaled(_ factor: Double) -> (FormatoPythonValue) -> FormatoValue? { { v in v.asFloat.map { .number($0 * factor) } } }
        put("Acquisition_instrument.SEM.beam_energy", "Beam", "HV", scaled(1e-3), rule: "rsciio mapping_fei: float(x) * 1e-3")
        put("Acquisition_instrument.SEM.Stage.x", "Stage", "StageX", raw, rule: "rsciio mapping_fei: as is")
        put("Acquisition_instrument.SEM.Stage.y", "Stage", "StageY", raw, rule: "rsciio mapping_fei: as is")
        put("Acquisition_instrument.SEM.Stage.z", "Stage", "StageZ", raw, rule: "rsciio mapping_fei: as is")
        put("Acquisition_instrument.SEM.Stage.rotation", "Stage", "StageR", raw, rule: "rsciio mapping_fei: as is")
        put("Acquisition_instrument.SEM.Stage.tilt", "Stage", "StageT", raw, rule: "rsciio mapping_fei: as is")
        put("Acquisition_instrument.SEM.working_distance", "Stage", "WorkingDistance", scaled(1e3), rule: "rsciio mapping_fei: float(x) * 1e3")
        put("Acquisition_instrument.SEM.dwell_time", "Scan", "Dwelltime", raw, rule: "rsciio mapping_fei: as is")
        put("Acquisition_instrument.SEM.beam_current", "EBeam", "BeamCurrent", scaled(1e9), rule: "rsciio mapping_fei: float(x) * 1e9")
        put("Acquisition_instrument.SEM.microscope", "System", "SystemType", raw, rule: "rsciio mapping_fei: as is")
        put("General.authors", "User", "User", raw, rule: "rsciio mapping_fei: as is")
        try put("General.date", "User", "Date", { v in
            guard case .string(let s) = v, let d = feiDate(s) else { throw FormatoReadError.unsupported("FEI User.Date '\(v)' is in a form this port of dateutil does not parse.") }
            return .text(d)
        }, rule: "rsciio mapping_fei: dateutil.parser.parse(x).date().isoformat()")
        try put("General.time", "User", "Time", { v in
            guard case .string(let s) = v, let t = feiTime(s) else { throw FormatoReadError.unsupported("FEI User.Time '\(v)' is in a form this port of dateutil does not parse.") }
            return .text(t)
        }, rule: "rsciio mapping_fei: dateutil.parser.parse(x).time().isoformat()")
    }

    /// dateutil's parse of an FEI date, for the forms ported: "MM/DD/YYYY" (month first, dateutil's default) and
    /// "YYYY-MM-DD".
    static func feiDate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        func fields(_ sep: Character) -> [Int]? {
            let parts = t.split(separator: sep, omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
            return parts.map { Int($0)! }
        }
        // dateutil raises on a date the calendar does not hold.
        func valid(_ y: Int, _ m: Int, _ d: Int) -> String? {
            let cal = Calendar(identifier: .gregorian)
            guard y >= 1000, (1...12).contains(m), let first = cal.date(from: DateComponents(year: y, month: m)),
                  let days = cal.range(of: .day, in: .month, for: first), days.contains(d) else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        if let us = fields("/") { return valid(us[2], us[0], us[1]) }
        if let iso = fields("-") { return valid(iso[0], iso[1], iso[2]) }
        return nil
    }

    /// dateutil's parse of an FEI time, for "H:MM:SS" with an optional AM/PM, as `time().isoformat()`.
    static func feiTime(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespaces).uppercased()
        var pm: Bool?
        if t.hasSuffix(" AM") || t.hasSuffix(" PM") { pm = t.hasSuffix("PM"); t = String(t.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let h0 = Int(parts[0]), let mi = Int(parts[1]) else { return nil }
        let sec = parts.count == 3 ? Int(parts[2]) : 0
        guard let sec, (0...59).contains(mi), (0...59).contains(sec) else { return nil }
        var h = h0
        if let pm {
            guard (1...12).contains(h) else { return nil }
            if pm && h != 12 { h += 12 } else if !pm && h == 12 { h = 0 }
        }
        guard (0...23).contains(h) else { return nil }
        return String(format: "%02d:%02d:%02d", h, mi, sec)
    }
}

extension FormatoPythonValue {
    /// The number an int or float holds (ImageJ's `spacing`); nil for a bool or string.
    var numberValue: Double? {
        switch self { case .int(let i): return Double(i); case .float(let d): return d; case .bool(let b): return b ? 1 : 0; default: return nil }
    }
}

/// A series as a lazy array: a slab reads, for each image it covers, the rows it needs and cuts the columns.
public nonisolated struct TIFFSeriesArray: FormatoLazyArray {
    public let path: String
    let series: TIFFSeries
    public let shape: [Int]
    public var dataType: FormatoDataType { series.dataType }

    /// The last two dimensions are a page's rows and columns and the others count the images (every series but some shaped
    /// ones): the read goes by image and row. Otherwise it goes by run of the last dimension through the flat element order.
    let rowsAndColumns: Bool

    init(path: String, series: TIFFSeries, shape: [Int]) {
        self.path = path
        self.series = series
        self.shape = shape
        let page = series.pages[0]
        let images = series.virtualCount ?? series.pages.count
        rowsAndColumns = shape.count >= 2 && shape[shape.count - 2] == page.height && shape[shape.count - 1] == page.width
            && shape.dropLast(2).reduce(1, *) == images
    }

    public func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        let rank = shape.count
        let el = dataType.byteSize
        guard rowsAndColumns else { return try readFlat(start: start, count: count) }
        let outerShape = Array(shape.prefix(rank - 2)), outerStart = Array(start.prefix(rank - 2)), outerCount = Array(count.prefix(rank - 2))
        let (y0, ny, x0, nx) = (start[rank - 2], count[rank - 2], start[rank - 1], count[rank - 1])
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FormatoReadError.cannotOpen(formatoDisplayFileName(path), String(cString: strerror(errno))) }
        defer { close(fd) }
        var out = Data()
        out.reserveCapacity(count.reduce(1, *) * el)
        // Every outer index in C order, as a flat image number.
        var images: [Int] = []
        if outerShape.isEmpty { images = [0] } else if !outerCount.contains(0) {
            var idx = [Int](repeating: 0, count: outerShape.count)
            while true {
                var flat = 0
                for k in 0..<outerShape.count { flat = flat * outerShape[k] + outerStart[k] + idx[k] }
                images.append(flat)
                var k = outerShape.count - 1
                while k >= 0 { idx[k] += 1; if idx[k] < outerCount[k] { break }; idx[k] = 0; k -= 1 }
                if k < 0 { break }
            }
        }
        for image in images {
            let src = series.source(image)
            for y in y0..<(y0 + ny) where nx > 0 {
                var row = Data(count: nx * el)
                let at = src.layout.rowOffset(y) + src.shift + x0 * el
                let got = row.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, nx * el, off_t(at)) }
                guard got == nx * el else { throw FormatoReadError.truncated(formatoDisplayFileName(path)) }
                src.layout.toLittleEndian(&row)
                out.append(row)
            }
        }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }

    /// A shaped series whose dimensions are not images, rows and columns (a shape with trailing 1s, say): the elements in C
    /// order are the pages' elements one after the other, and a run of the last dimension is read row segment by row segment.
    private func readFlat(start: [Int], count: [Int]) throws -> FormatoArray {
        let el = dataType.byteSize
        let page = series.pages[0]
        let (width, pageElements) = (page.width, page.width * page.height)
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FormatoReadError.cannotOpen(formatoDisplayFileName(path), String(cString: strerror(errno))) }
        defer { close(fd) }
        var out = Data()
        out.reserveCapacity(count.reduce(1, *) * el)
        guard !count.contains(0) else { return try FormatoArray(dataType: dataType, shape: count, bytes: out) }
        let rank = shape.count
        var strides = [Int](repeating: 1, count: rank)
        for k in stride(from: rank - 2, through: 0, by: -1) { strides[k] = strides[k + 1] * shape[k + 1] }
        var idx = [Int](repeating: 0, count: max(rank - 1, 0))
        while true {
            // Rank 0 (tifffile's shape () series) is the page's one value: flat 0, one element.
            var flat = rank > 0 ? start[rank - 1] : 0
            for k in 0..<max(rank - 1, 0) { flat += (start[k] + idx[k]) * strides[k] }
            var remaining = rank > 0 ? count[rank - 1] : 1
            while remaining > 0 {
                let image = flat / pageElements, within = flat % pageElements
                let (y, x) = (within / width, within % width)
                let take = min(remaining, width - x)
                let src = series.source(image)
                var run = Data(count: take * el)
                let at = src.layout.rowOffset(y) + src.shift + x * el
                let got = run.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, take * el, off_t(at)) }
                guard got == take * el else { throw FormatoReadError.truncated(formatoDisplayFileName(path)) }
                src.layout.toLittleEndian(&run)
                out.append(run)
                flat += take; remaining -= take
            }
            var k = rank - 2
            while k >= 0 { idx[k] += 1; if idx[k] < count[k] { break }; idx[k] = 0; k -= 1 }
            if k < 0 { break }
        }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }
}
