// EMPAD XML and little-endian float32 frames; RosettaSciIO 049e7d70 empad/_api.py (GPL-3.0-or-later).
import Foundation
import Darwin
import FormatoCore

/// Failures opening or validating an EMPAD pair. Invalid dimensions and calibrations are refused before mapping.
public nonisolated enum EMPADError: Error, Sendable, Equatable {
    /// A companion file could not be opened or memory-mapped.
    case cannotOpen(String)
    /// The XML is malformed, lacks a required field, or contains an unsupported value.
    case invalidXML(String)
    /// The raw length must match the XML exactly, including the two footer rows of every frame.
    case rawSizeMismatch(expected: Int, actual: Int)
}

/// An EMPAD XML header and its raw frames, exposed as a lazy FormatoCore signal.
///
/// Reads RosettaSciIO's legacy `pix_x/pix_y`, modern `scan_xN_yN.raw` names and image series.
/// Stored frames are 130 rows by 128 columns of little-endian Float32; the last two rows are omitted.
/// Singleton axes are squeezed, and uncalibrated diffraction axes use empty units (RosettaSciIO's `None`).
/// The raw file is memory-mapped read-only; callers must keep it unchanged while the reader or signal exists.
public nonisolated struct EMPADReader: Sendable {
    /// The signal; only requested slabs are copied from the mapping. `load()` reads every detector pixel.
    public let signal: FormatoLazySignal
    /// The raw file the frames come from, after the XML's `raw_file.filename` was resolved against the XML's folder.
    public let rawPath: String

    /// Opens an XML header (or a raw path with a same-stem XML companion).
    /// - Parameters:
    ///   - path: The XML or raw file path. XML `raw_file.filename` resolves relative to the XML directory.
    ///   - qCalibration: Optional diffraction scale in 1/nm, overriding XML `calibrated_pixelsize`.
    ///     The default uses the XML value times 1e9, or pixel scales if absent.
    /// - Throws: `EMPADError` for missing files, invalid headers, overflowing dimensions or incorrect raw length.
    public init(path: String, qCalibration: Double? = nil) throws {
        let input = URL(fileURLWithPath: path)
        let xml = input.pathExtension.lowercased() == "raw" ? input.deletingPathExtension().appendingPathExtension("xml") : input
        guard let parser = XMLParser(contentsOf: xml) else { throw EMPADError.cannotOpen(xml.lastPathComponent) }
        let header = Header()
        parser.delegate = header
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw EMPADError.invalidXML("Malformed XML") }
        try self.init(xml: xml, fields: header.fields, qCalibration: qCalibration)
    }

    /// Opens a raw file that has no XML header: `scan_x{N}_y{M}` in its name, `scanSize` when given, or else a square scan
    /// whose frame count is the file's. Calibrations are absent (pixels), as RosettaSciIO's for an XML without them.
    /// - Parameter scanSize: `(y, x)` scan extents; they must account for the file's length exactly.
    /// - Throws: `EMPADError.invalidXML("Missing scan dimensions")` when neither the name nor the length gives a scan.
    public init(rawPath: String, scanSize: (y: Int, x: Int)? = nil, qCalibration: Double? = nil) throws {
        let raw = URL(fileURLWithPath: rawPath)
        var fields = ["root.raw_file.filename": raw.lastPathComponent]
        if let scanSize {
            guard scanSize.y > 0, scanSize.x > 0 else { throw EMPADError.invalidXML("Invalid scan dimension") }
            fields["root.scan_parameters.scan_resolution_x"] = String(scanSize.x)
            fields["root.scan_parameters.scan_resolution_y"] = String(scanSize.y)
        } else if !raw.lastPathComponent.hasPrefix("scan_") {
            var info = stat()
            guard stat(rawPath, &info) == 0 else { throw EMPADError.cannotOpen(raw.lastPathComponent) }
            let frame = 130 * 128 * 4
            let frames = Int(info.st_size) / frame
            let side = Int(Double(frames).squareRoot().rounded())
            guard frames > 0, side * side == frames else { throw EMPADError.invalidXML("Missing scan dimensions") }
            fields["root.scan_parameters.scan_resolution_x"] = String(side)
            fields["root.scan_parameters.scan_resolution_y"] = String(side)
        }
        try self.init(xml: raw, fields: fields, qCalibration: qCalibration)
    }

    private init(xml: URL, fields: [String: String], qCalibration: Double?) throws {
        guard let filename = fields["root.raw_file.filename"], !filename.isEmpty else {
            throw EMPADError.invalidXML("Missing raw_file.filename")
        }
        func positive(_ text: String?) throws -> Int {
            guard let text, let n = Int(text), n > 0 else { throw EMPADError.invalidXML("Invalid scan dimension") }
            return n
        }
        var dimensions: [Int]
        var names: [String]
        if let series = fields["root.scan_parameters.series_count"] {
            dimensions = [try positive(series)]; names = ["series_count"]
        } else {
            let x: Int, y: Int
            if let px = fields["root.pix_x"], let py = fields["root.pix_y"] {
                x = try positive(px); y = try positive(py)
            } else if let rx = fields["root.scan_parameters.scan_resolution_x"], let ry = fields["root.scan_parameters.scan_resolution_y"] {
                // `scan_parameters mode="acquire"`: the acquisition's own extents, whatever the raw file is called.
                x = try positive(rx); y = try positive(ry)
            } else {
                let parts = filename.components(separatedBy: ".")[0].components(separatedBy: "_")
                guard filename.hasPrefix("scan_"), parts.count >= 3,
                      parts[parts.count - 2].hasPrefix("x"), parts.last!.hasPrefix("y") else {
                    throw EMPADError.invalidXML("Missing scan dimensions")
                }
                x = try positive(String(parts[parts.count - 2].dropFirst()))
                y = try positive(String(parts.last!.dropFirst()))
            }
            dimensions = [y, x]; names = ["scan_y", "scan_x"]
        }
        var expected = 130 * 128 * 4
        for n in dimensions {
            let (next, overflow) = expected.multipliedReportingOverflow(by: n)
            guard !overflow else { throw EMPADError.invalidXML("Scan dimensions overflow") }
            expected = next
        }
        var scales = dimensions.map { _ in 1.0 }
        var units = dimensions.count == 1 ? ["ms"] : ["", ""]
        func number(_ text: String) throws -> Double {
            guard let n = Double(text), n.isFinite else { throw EMPADError.invalidXML("Invalid numeric calibration") }
            return n
        }
        // EMPAD's compact conversion uses factor, whereas Velox's helper uses factor / 2.
        func compact(_ value: Double, factor: Int = 1) throws -> (Double, String) {
            guard let converted = FormatoUnits.convertScaleUnits(value, units: "m", factor: factor * 2) else {
                throw EMPADError.invalidXML("Unrepresentable navigation calibration")
            }
            return (converted.value, converted.units)
        }
        if dimensions.count == 2 {
            if let text = fields["root.iom_measurements.optics.get_full_scan_field_of_view"] {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let first = trimmed.first, let last = trimmed.last,
                      (first == "[" && last == "]") || (first == "(" && last == ")") else {
                    throw EMPADError.invalidXML("Invalid field of view")
                }
                let parts = trimmed.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw EMPADError.invalidXML("Invalid field of view") }
                for i in 0..<2 {
                    (scales[i], units[i]) = try compact(number(String(parts[i]).trimmingCharacters(in: .whitespacesAndNewlines)) / Double(dimensions[i]), factor: dimensions[i])
                }
            } else if let fov = fields["root.iom_measurements.full_scan_field_of_view.x"],
                      let factor = fields["root.iom_measurements.full_scan_field_of_view.scale_factor"] {
                let divisor = try number(factor)
                guard divisor != 0 else { throw EMPADError.invalidXML("Zero field-of-view scale factor") }
                let converted = try compact(number(fov) / divisor / Double(dimensions.max()!))
                scales = [converted.0, converted.0]; units = [converted.1, converted.1]
            }
        }
        let q: Double
        let qUnits: String
        if let qCalibration {
            guard qCalibration.isFinite else { throw EMPADError.invalidXML("Invalid q calibration") }
            q = qCalibration; qUnits = "1/nm"
        } else if let text = fields["root.iom_measurements.calibrated_pixelsize"] {
            q = try number(text) * 1e9; qUnits = "1/nm"
            guard q.isFinite else { throw EMPADError.invalidXML("Overflowing q calibration") }
        } else { q = 1; qUnits = "" }
        let navigationRank = dimensions.count
        dimensions += [128, 128]; names += ["height", "width"]
        scales += [q, q]; units += [qUnits, qUnits]
        let axes = dimensions.indices.filter { dimensions[$0] > 1 }.map { i in
            FormatoAxis(name: names[i], size: dimensions[i], scale: scales[i],
                        offset: (i < navigationRank ? 0.0 : -64.0) * scales[i], units: units[i], navigate: i < navigationRank)
        }
        let title = xml.deletingPathExtension().lastPathComponent
        var metadata = FormatoMetadata()
        func entry(_ key: String, _ value: String, _ source: String) {
            metadata.set(FormatoMetadataEntry(key: key, value: .text(value), units: nil,
                provenance: FormatoProvenance(file: xml.lastPathComponent, source: source, rule: "rsciio empad file_reader")))
        }
        entry("General.original_filename", xml.lastPathComponent, "XML filename")
        entry("General.title", title, "XML filename stem")
        entry("Signal.signal_type", "electron_diffraction", "EMPAD format")
        if let timestamp = fields["root.timestamp.isoformat"] {
            let parts = timestamp.components(separatedBy: "T")
            guard parts.count == 2 else { throw EMPADError.invalidXML("Invalid timestamp") }
            entry("General.date", parts[0], "root.timestamp.isoformat")
            entry("General.time", parts[1], "root.timestamp.isoformat")
        }
        let raw = URL(fileURLWithPath: filename, relativeTo: xml.deletingLastPathComponent()).standardizedFileURL
        let mapping = try Mapping(path: raw.path, expected: expected)
        rawPath = raw.path
        signal = FormatoLazySignal(title: title, signalType: "electron_diffraction", axes: axes, metadata: metadata,
                                 array: EMPADArray(mapping: mapping, shape: axes.map(\.size)))
    }
}

private final class Header: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    var stack: [String] = []
    var texts: [String] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); texts.append("")
        for (key, value) in attributes { store(stack.joined(separator: ".") + "." + key, value) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !texts.isEmpty { texts[texts.count - 1] += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        store(stack.joined(separator: "."), texts.removeLast().trimmingCharacters(in: .whitespacesAndNewlines))
        stack.removeLast()
    }
    func store(_ key: String, _ value: String) {
        fields[key] = value
    }
}

// Immutable read-only mapping shared across concurrent slab reads; lifetime owns both fd and address.
private final class Mapping: @unchecked Sendable {
    let fd: Int32
    let pointer: UnsafeMutableRawPointer
    let length: Int
    init(path: String, expected: Int) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw EMPADError.cannotOpen(URL(fileURLWithPath: path).lastPathComponent) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { close(descriptor); throw EMPADError.cannotOpen(path) }
        guard info.st_size == expected else {
            close(descriptor); throw EMPADError.rawSizeMismatch(expected: expected, actual: Int(info.st_size))
        }
        guard let address = mmap(nil, expected, PROT_READ, MAP_PRIVATE, descriptor, 0), address != MAP_FAILED else {
            close(descriptor); throw EMPADError.cannotOpen(path)
        }
        fd = descriptor; pointer = address; length = expected
    }
    deinit { munmap(pointer, length); close(fd) }
    func checkSize() throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw EMPADError.cannotOpen("raw file") }
        guard info.st_size == length else { throw EMPADError.rawSizeMismatch(expected: length, actual: Int(info.st_size)) }
    }
}

private struct EMPADArray: FormatoLazyArray {
    let mapping: Mapping
    let shape: [Int]
    var dataType: FormatoDataType { .float32 }
    func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.checkSlab(start: start, count: count, shape: shape)
        try mapping.checkSize()
        var bytes = Data(capacity: try FormatoArray.elementCount(count) * 4)
        FormatoArray.forEachRun(start: start, count: count, shape: shape) { element, length in
            let frame = element / (128 * 128)
            let pixel = element % (128 * 128)
            bytes.append(mapping.pointer.advanced(by: (frame * 130 * 128 + pixel) * 4).assumingMemoryBound(to: UInt8.self), count: length * 4)
        }
        return try FormatoArray(dataType: .float32, shape: count, bytes: bytes)
    }
}
