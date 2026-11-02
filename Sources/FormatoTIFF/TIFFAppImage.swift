//
//  TIFFAppImage.swift
//  The first consumer's reading of one 2D TIFF image as a Float32 calibrated image: the named option beside `TIFFSignals`
//  (RosettaSciIO's and tifffile's reading). Pinned to the consumer's source (macTEM cb6e164 TIFFImageReader.swift),
//  compiled unchanged by tools/acq-metadata/generate.py (the `app-image` pass), over the kit's `TIFFFile` tag walker.
//
//  WHAT IS READ: a baseline TIFF (II or MM), its first image file directory only, uncompressed, in strips, chunky. One
//  sample per pixel: unsigned or signed 8/16/32-bit integers, 32/64-bit floats, each as Float32. Three samples (RGB, 8 bit
//  only): only when R = G = B holds exactly at every pixel (an exported grey render), read as one grey channel and noted
//  "8-bit render, not counts". Refused by name (`Refusal`): not a TIFF, BigTIFF, a file that ends before its image does,
//  a second page or an ImageJ stack (more than one plane), any compression, tiles, unequal colour channels, any other
//  sample layout (WhiteIsZero, palette, 16-bit colour, planar 2, mixed sample sizes). Nothing is guessed.
//
//  CALIBRATION, in this order: FEI SEM INI (tag 34680 or 34682): `[Scan] PixelWidth/PixelHeight` in metres, else
//  `[IRBeam] HFW/VFW` over `[Image] ResolutionX/Y`; a value that is not a number leaves both axes uncalibrated. Otherwise
//  the Velox XML (tag 34683, `TIFFVeloxCalibration`) cross-checked against tags 65450 to 65452. Otherwise Digital
//  Micrograph tags (65003 to 65025: units, scale, offset; origin = -offset / scale), then ImageJ (an ImageDescription that
//  starts "ImageJ="; 1 / XResolution and 1 / YResolution, only with a `unit=` line; only "micron" (as "µm") sets a unit, so
//  any other ImageJ unit, "nm" included, is uncalibrated unless Digital Micrograph tags named one; a file with a `unit=` line
//  and no resolution tags opens uncalibrated).
//
//  DIFFERENCES from `TIFFSignals`: Float32 pixels (not the stored type); RGB only as an exact grey render; a stack or a
//  second page refused (TIFFSignals reads series); BigTIFF refused; a vendor branch (Zeiss, TVIPS, ...) is not refused by
//  name; WhiteIsZero and palette refused (TIFFSignals reads the stored values); FEI SEM: PixelWidth is the x scale (tifffile
//  puts the width's scale on the height axis, so the two agree only on square pixels); a DM scale of 0 is no axis (not a
//  calibrated one); a non-numeric FEI value leaves both axes uncalibrated; an axis without a unit is nil. A tag whose value
//  lies outside the file is `truncated` here (`TIFFFile` checks every value); the consumer's lazy walker reads it as absent.
//

import Foundation
import FormatoCore

public nonisolated enum TIFFAppImage {

    /// One calibrated axis: the physical value at pixel `i` is `(i - origin) * scale`.
    public struct Axis: Sendable, Equatable {
        public let origin: Double
        public let scale: Double
        public let units: String

        public init(origin: Double, scale: Double, units: String) {
            self.origin = origin; self.scale = scale; self.units = units
        }
    }

    /// One 2D Float32 image and the calibration of each axis, nil where the file gives none.
    public struct Image: Sendable, Equatable {
        public let width: Int
        public let height: Int
        /// Row-major, `width` fastest.
        public let pixels: [Float]
        public let x: Axis?
        public let y: Axis?
        public let fileName: String
        public let source: String
        public let notes: [String]
    }

    /// Why a TIFF is not read. Each names what the file holds, so the refusal is specific.
    public enum Refusal: Error, Equatable, Sendable {
        case notTIFF
        case truncated
        case multiPage
        case compressed(scheme: Int)
        case tiled
        case unequalChannels(row: Int, column: Int)
        case sampleFormat(String)

        /// One sentence for the person who opened the file.
        public var reason: String {
            switch self {
            case .notTIFF: "it is not a TIFF file."
            case .truncated: "the file ends before its image does."
            case .multiPage: "it holds more than one page; image stacks are not read yet."
            case .compressed(let scheme): "its pixels are compressed (scheme \(scheme)); only uncompressed TIFF is read."
            case .tiled: "its pixels are stored in tiles; only striped TIFF is read."
            case .unequalChannels(let row, let column):
                "it is a colour image (row \(row), column \(column) differs between red, green and blue); only a grey render is read."
            case .sampleFormat(let what): "its pixel layout is not read (\(what))."
            }
        }
    }

    /// The notes a reading can attach, worded once.
    public enum Note {
        public static let render = "8-bit render, not counts"
        public static let veloxStoredScale = TIFFVeloxCalibration.storedScaleNote
        /// The same note under its older name.
        public static let veloxUnvalidated = veloxStoredScale
        public static let veloxDisagree = TIFFVeloxCalibration.disagreeNote
    }

    // MARK: - Reading

    public static func read(path: String, acceptUnequalChannels: Bool = false) throws -> Image {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
            throw FormatoReadError.cannotOpen(formatoDisplayFileName(path), error.localizedDescription)
        }
        return try read(data: data, fileName: formatoDisplayFileName(path), acceptUnequalChannels: acceptUnequalChannels)
    }

    /// `acceptUnequalChannels` exists for one caller: the negative control that must show the unequal-channel refusal is
    /// live. It reads the red channel instead of refusing.
    public static func read(data: Data, fileName: String, acceptUnequalChannels: Bool = false) throws -> Image {
        try checkFirstDirectory(data)
        let file: TIFFFile
        do { file = try TIFFFile(data: data, path: fileName) } catch TIFFError.notTIFF { throw Refusal.notTIFF } catch {
            throw Refusal.truncated
        }
        guard let first = file.directories.first else { throw Refusal.truncated }
        // The consumer's dictionary keeps the last of a repeated tag.
        var byCode: [Int: TIFFTag] = [:]
        for tag in first.tags { byCode[tag.code] = tag }
        let page = TIFFDirectory(offset: first.offset, tags: Array(byCode.values))
        let tags = Tags(byCode: byCode, bigEndian: file.bigEndian)

        // An ImageJ stack can sit in ONE directory (its description counts the planes, the data is contiguous): more than
        // one plane is a stack, refused like a second page, never read as its first frame.
        if let description = tags.string(byCode[270]), description.hasPrefix("ImageJ=") {
            let planes = ["images", "slices", "frames", "channels"].reduce(1) { product, key in
                product * max(1, Int(imageJ(description)[key] ?? "") ?? 1)
            }
            if planes > 1 { throw Refusal.multiPage }
        }
        guard let width = tags.integer(byCode[256]), let height = tags.integer(byCode[257]), width > 0, height > 0 else {
            throw Refusal.sampleFormat("no image width or height")
        }
        let compression = tags.integer(byCode[259]) ?? 1
        guard compression == 1 else { throw Refusal.compressed(scheme: compression) }
        if byCode[322] != nil || byCode[324] != nil { throw Refusal.tiled }
        let samples = tags.integer(byCode[277]) ?? 1
        let planar = tags.integer(byCode[284]) ?? 1
        let bits = tags.integers(byCode[258]) ?? [1]
        let formats = tags.integers(byCode[339]) ?? [1]
        let photometric = tags.integer(byCode[262]) ?? -1
        guard let bitsPerSample = bits.first, bits.allSatisfy({ $0 == bitsPerSample }),
              let format = formats.first, formats.allSatisfy({ $0 == format }) else {
            throw Refusal.sampleFormat("mixed sample sizes or formats")
        }
        // Grey is BlackIsZero (1) or no photometric tag; WhiteIsZero (0) and palettes are refused, not inverted.
        let isGrey = samples == 1 && (photometric == 1 || photometric == -1)
        let isRGB = samples == 3 && photometric == 2 && planar == 1 && format == 1 && bitsPerSample == 8
        guard isGrey || isRGB else {
            throw Refusal.sampleFormat("\(samples) sample(s) per pixel, photometric \(photometric), planar \(planar)")
        }
        let decode = try decoder(bits: bitsPerSample, format: format, bigEndian: file.bigEndian)

        // The strips, concatenated in order, must hold exactly the image.
        guard let offsets = tags.integers(byCode[273]), let counts = tags.integers(byCode[279]),
              offsets.count == counts.count, !offsets.isEmpty else {
            throw Refusal.sampleFormat("no strips")
        }
        let bytesPerSample = bitsPerSample / 8
        // The size the header claims, without overflow, against what the strips hold, before any allocation: a corrupt
        // width or height is a refusal, never a trap or an allocation of the claimed size.
        var needed = width
        for factor in [height, samples, bytesPerSample] {
            let (product, overflow) = needed.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw Refusal.truncated }
            needed = product
        }
        var stripped = 0
        for (offset, count) in zip(offsets, counts) {
            guard offset >= 0, count >= 0, count <= data.count, offset <= data.count - count else { throw Refusal.truncated }
            stripped += count
        }
        guard stripped >= needed else { throw Refusal.truncated }
        var raw = Data(capacity: stripped)
        for (offset, count) in zip(offsets, counts) {
            raw.append(data[data.startIndex + offset ..< data.startIndex + offset + count])
        }

        var pixels = [Float](repeating: 0, count: width * height)
        try raw.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            if isRGB {
                for i in 0..<(width * height) {
                    let base = i * 3 * bytesPerSample
                    let r = decode(buffer, base), g = decode(buffer, base + bytesPerSample),
                        b = decode(buffer, base + 2 * bytesPerSample)
                    guard acceptUnequalChannels || r == g && g == b else {
                        throw Refusal.unequalChannels(row: i / width, column: i % width)
                    }
                    pixels[i] = r
                }
            } else {
                for i in 0..<(width * height) { pixels[i] = decode(buffer, i * bytesPerSample) }
            }
        }

        var notes: [String] = []
        if isRGB { notes.append(Note.render) }
        let (x, y, calibrationNotes, source) = calibration(tags, page)
        notes += calibrationNotes
        let kind = isRGB ? "RGB render" : "\(format == 3 ? "float" : format == 2 ? "int" : "uint")\(bitsPerSample)"
        return Image(width: width, height: height, pixels: pixels, x: x, y: y, fileName: fileName,
                     source: (["TIFF · \(kind)", source].compactMap { $0 } + notes).joined(separator: " · "), notes: notes)
    }

    // MARK: - The header and the first directory

    /// What the consumer's walker checks before it looks at a tag, in its order: eight bytes, the byte order, the magic
    /// (BigTIFF is refused by name), the first directory's table inside the file, then a following directory.
    private static func checkFirstDirectory(_ data: Data) throws {
        guard data.count >= 8 else { throw Refusal.notTIFF }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        guard (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) else { throw Refusal.notTIFF }
        let reader = ByteReader(data: data, bigEndian: b0 == 0x4D)
        let magic = reader.u16u(2)
        if magic == 43 { throw Refusal.sampleFormat("BigTIFF") }
        guard magic == 42 else { throw Refusal.notTIFF }
        let start = Int(reader.u32u(4))
        guard start + 2 <= data.count else { throw Refusal.truncated }
        let n = Int(reader.u16u(start))
        guard start + 2 + 12 * n + 4 <= data.count else { throw Refusal.truncated }
        if reader.u32u(start + 2 + 12 * n) != 0 { throw Refusal.multiPage }
    }

    /// The tag values as the consumer's walker decodes them, from the bytes `TIFFFile` stored (its own decoders differ for
    /// the types the consumer does not read: SBYTE, SRATIONAL, IFD, LONG8, which are absent here too).
    private struct Tags {
        let byCode: [Int: TIFFTag]
        let bigEndian: Bool

        func integers(_ tag: TIFFTag?) -> [Int]? {
            guard let tag else { return nil }
            let r = ByteReader(data: tag.raw, bigEndian: bigEndian)
            switch tag.type {
            case 1, 7: return (0..<tag.count).map { Int(r.u8($0)) }
            case 3: return (0..<tag.count).map { Int(r.u16u(2 * $0)) }
            case 8: return (0..<tag.count).map { Int(Int16(bitPattern: r.u16u(2 * $0))) }
            case 4: return (0..<tag.count).map { Int(r.u32u(4 * $0)) }
            case 9: return (0..<tag.count).map { Int(Int32(bitPattern: r.u32u(4 * $0))) }
            default: return nil
            }
        }

        func integer(_ tag: TIFFTag?) -> Int? { integers(tag)?.first }

        /// The first value of a FLOAT, DOUBLE, RATIONAL or integer tag, as a Double.
        func double(_ tag: TIFFTag?) -> Double? {
            guard let tag, tag.count >= 1 else { return nil }
            let r = ByteReader(data: tag.raw, bigEndian: bigEndian)
            switch tag.type {
            case 11: return Double(Float(bitPattern: r.u32u(0)))
            case 12: return Double(bitPattern: r.u64u(0))
            case 5:
                let d = r.u32u(4)
                return d == 0 ? nil : Double(r.u32u(0)) / Double(d)
            default: return integer(tag).map(Double.init)
            }
        }

        /// A RATIONAL tag's first value as (numerator, denominator); a zero numerator is no value.
        func rational(_ tag: TIFFTag?) -> (numerator: Double, denominator: Double)? {
            guard let tag, tag.type == 5, tag.raw.count >= 8 else { return nil }
            let r = ByteReader(data: tag.raw, bigEndian: bigEndian)
            let n = r.u32u(0)
            return n == 0 ? nil : (Double(n), Double(r.u32u(4)))
        }

        /// An ASCII or UNDEFINED tag as ISO Latin-1 text (DM's unit strings: "µm" is 0xB5 'm'), NULs dropped.
        func latin1(_ tag: TIFFTag?) -> String? {
            guard let tag, tag.type == 2 || tag.type == 7 else { return nil }
            return String(bytes: tag.raw.filter { $0 != 0 }, encoding: .isoLatin1)
        }

        /// An ASCII or UNDEFINED tag as UTF-8 text, trailing NULs dropped, not stripped.
        func string(_ tag: TIFFTag?) -> String? {
            guard let tag, tag.type == 2 || tag.type == 7 else { return nil }
            return String(decoding: tag.raw.reversed().drop(while: { $0 == 0 }).reversed(), as: UTF8.self)
        }
    }

    /// Bytes at a buffer offset to Float, for one sample type. Signed and unsigned integers, IEEE floats.
    private static func decoder(bits: Int, format: Int, bigEndian: Bool)
        throws -> (UnsafeRawBufferPointer, Int) -> Float {
        func load<T: FixedWidthInteger>(_: T.Type) -> (UnsafeRawBufferPointer, Int) -> T {
            { b, o in let v = b.loadUnaligned(fromByteOffset: o, as: T.self); return bigEndian ? T(bigEndian: v) : T(littleEndian: v) }
        }
        switch (format, bits) {
        case (1, 8):  let l = load(UInt8.self);  return { Float(l($0, $1)) }
        case (1, 16): let l = load(UInt16.self); return { Float(l($0, $1)) }
        case (1, 32): let l = load(UInt32.self); return { Float(l($0, $1)) }
        case (2, 8):  let l = load(Int8.self);   return { Float(l($0, $1)) }
        case (2, 16): let l = load(Int16.self);  return { Float(l($0, $1)) }
        case (2, 32): let l = load(Int32.self);  return { Float(l($0, $1)) }
        case (3, 32): let l = load(UInt32.self); return { Float(bitPattern: l($0, $1)) }
        case (3, 64): let l = load(UInt64.self); return { Float(Double(bitPattern: l($0, $1))) }
        default: throw Refusal.sampleFormat("\(bits)-bit samples of format \(format)")
        }
    }

    // MARK: - Calibration

    /// The axes, the notes the calibration adds, and the convention's name for `source`.
    private static func calibration(_ tags: Tags, _ page: TIFFDirectory) -> (Axis?, Axis?, [String], String?) {
        let byCode = tags.byCode
        if byCode[34680] != nil || byCode[34682] != nil {
            // tifffile's `fei_metadata`: the SFEG sections, then the Helios ones, a later section replacing an earlier.
            var sections: [String: [String: String]] = [:]
            for code in [34680, 34682] {
                if let ini = tags.string(byCode[code]) { sections.merge(feiSections(ini)) { _, later in later } }
            }
            let (x, y) = fei(sections)
            return (x, y, [], "FEI metadata")
        }
        if let velox = TIFFVeloxCalibration.read(consumersView(of: page, tags)) {
            switch velox {
            case .disagree: return (nil, nil, [Note.veloxDisagree], "Velox metadata")
            case .calibrated(let xScale, let xUnit, let yScale, let yUnit):
                return (calibratedAxis(origin: 0, scale: xScale, units: xUnit), calibratedAxis(origin: 0, scale: yScale, units: yUnit),
                        [Note.veloxUnvalidated], "Velox metadata")
            }
        }
        var x: (scale: Double, offset: Double, units: String?) = (1, 0, nil)
        var y = x
        var name: String?
        let dmTags = [65003, 65004, 65005, 65009, 65010, 65011, 65006, 65007, 65008, 65022, 65024, 65025]
        if dmTags.contains(where: { byCode[$0] != nil }) {
            name = "Digital Micrograph tags"
            if let u = tags.latin1(byCode[65003]) { x.units = u }
            if let u = tags.latin1(byCode[65004]) { y.units = u }
            if let v = tags.double(byCode[65009]) { x.scale = v }
            if let v = tags.double(byCode[65010]) { y.scale = v }
            if let v = tags.double(byCode[65006]) { x.offset = v }
            if let v = tags.double(byCode[65007]) { y.offset = v }
        }
        if let description = tags.string(byCode[270]), description.hasPrefix("ImageJ=") {
            name = "ImageJ"
            if let unit = imageJ(description)["unit"] {
                // RosettaSciIO reads the resolution whenever a unit is named; without the tags it raises and the whole
                // image opens uncalibrated, DM's tags included.
                guard let rx = tags.rational(byCode[282]), let ry = tags.rational(byCode[283]) else { return (nil, nil, [], name) }
                if unit == "micron" { x.units = "µm"; y.units = "µm" }
                x.scale = rx.denominator / rx.numerator
                y.scale = ry.denominator / ry.numerator
            }
        }
        func axis(_ a: (scale: Double, offset: Double, units: String?)) -> Axis? {
            guard let units = a.units, !units.isEmpty else { return nil }
            return calibratedAxis(origin: a.offset == 0 ? 0 : -a.offset / a.scale, scale: a.scale, units: units)
        }
        return (axis(x), axis(y), [], name)
    }

    /// `page` with the three resolution tags as the consumer's walker reads them, so `TIFFVeloxCalibration` (which decodes
    /// every TIFF type) answers as the consumer does: a value of a type the consumer does not decode is absent, an UNDEFINED
    /// byte is a number.
    private static func consumersView(of page: TIFFDirectory, _ tags: Tags) -> TIFFDirectory {
        var kept = page.tags.filter { ![65450, 65451, 65452].contains($0.code) }
        for code in [65450, 65451, 65452] {
            guard let tag = tags.byCode[code] else { continue }
            if code == 65452 {
                if let v = tags.integer(tag) {
                    kept.append(TIFFTag(code: code, type: 4, count: 1, valueOffset: tag.valueOffset, raw: tag.raw, value: .integers([Int64(v)])))
                }
            } else if let v = tags.double(tag) {
                kept.append(TIFFTag(code: code, type: 12, count: 1, valueOffset: tag.valueOffset, raw: tag.raw, value: .reals([v])))
            }
        }
        return TIFFDirectory(offset: page.offset, tags: kept)
    }

    /// An axis only when its scale is a physical sampling (finite, > 0), never a fabricated one.
    private static func calibratedAxis(origin: Double, scale: Double, units: String) -> Axis? {
        guard scale.isFinite, scale > 0, origin.isFinite else { return nil }
        return Axis(origin: origin, scale: scale, units: units)
    }

    /// An ImageJ description's `key=value` lines, keys and values trimmed as tifffile trims them.
    private static func imageJ(_ description: String) -> [String: String] {
        Dictionary(description.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { _, last in last })
    }

    /// One FEI INI text as tifffile's `read_fei_metadata` reads it: lines trimmed, a `[section]` starts a new, empty
    /// section (a repeated name replaces the earlier one), keys and values trimmed.
    private static func feiSections(_ ini: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for raw in ini.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { current = String(line.dropFirst().dropLast()); sections[current!] = [:]; continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard let current, parts.count == 2 else { continue }
            sections[current]?[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return sections
    }

    /// FEI SEM: [Scan] PixelWidth/PixelHeight in metres; only when [Scan] lacks them, [IRBeam] HFW/VFW over [Image]
    /// ResolutionX/Y. A value that is not a number leaves both axes uncalibrated. PixelWidth is x (see the header).
    private static func fei(_ sections: [String: [String: String]]) -> (Axis?, Axis?) {
        func metres(_ x: Double, _ y: Double) -> (Axis?, Axis?) {
            (calibratedAxis(origin: 0, scale: x, units: "m"), calibratedAxis(origin: 0, scale: y, units: "m"))
        }
        if let w = sections["Scan"]?["PixelWidth"], let h = sections["Scan"]?["PixelHeight"] {
            guard let w = Double(w), let h = Double(h) else { return (nil, nil) }
            return metres(w, h)
        }
        if let hfw = sections["IRBeam"]?["HFW"], let vfw = sections["IRBeam"]?["VFW"],
           let rx = sections["Image"]?["ResolutionX"], let ry = sections["Image"]?["ResolutionY"] {
            guard let hfw = Double(hfw), let vfw = Double(vfw), let rx = Double(rx), let ry = Double(ry) else {
                return (nil, nil)
            }
            return metres(hfw / rx, vfw / ry)
        }
        return (nil, nil)
    }
}
