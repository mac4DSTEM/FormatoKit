//
//  VeloxTitles.swift
//  Role: The title RosettaSciIO 049e7d70 gives each Velox image with `select_type="images"` (docs/registration-step-3.md
//        §3.2), ported rule for rule from `_emd_velox.py`: `read_file` (the four file-level groups, the image type),
//        `_parse_image_display` (the label maps), `_read_image` (DetectorInformation and the KeyError fallback, the name
//        carried from image to image) and `_get_detector_name` (the seven `Operations` kinds, in that order).
//        Python's KeyError, which `_read_image` catches around `_get_detector_name`, is `Fallback` here; whatever RosettaSciIO
//        raises on (another missing key, a non-JSON entry, a missing display group) refuses the file with its reason.
//

import Foundation
import FormatoCore
import FormatoHDF5

/// The title of each image of a Velox file, and where it came from.
nonisolated struct VeloxTitles: Sendable {
    struct Title: Sendable {
        /// nil when RosettaSciIO's metadata has no title (no name was ever found).
        let text: String?
        /// The rule and the JSON path that gave it (the `General.title` provenance).
        let source: String
    }
    let byImage: [String: Title]

    private struct Fallback: Error {}   // Python's KeyError inside `_get_detector_name`
    /// A child of one of the four file-level groups: a group's datasets by name (as `{name: json}`), or one dataset's JSON.
    private struct Entry { let path: String; let isGroup: Bool; let value: Any }
    private static let kinds = ["CameraInputOperation", "StemInputOperation", "SurfaceReconstructionOperation",
                                "MathematicsOperation", "DpcOperation", "IntegrationOperation", "FftOperation"]

    /// Reads the file's titles. Must run inside `HDF5Serial.run`.
    init(file: VeloxFile, fileName: String) throws {
        func refuse(_ why: String) -> FormatoReadError { .unsupported("Velox file \(fileName): \(why) (RosettaSciIO raises).") }
        func json(_ path: String) throws -> Any {
            guard let text = file.readString(path) else { throw refuse("\(path) is not one variable-length string") }
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else {
                throw refuse("\(path) is not JSON")
            }
            return value
        }
        func isDataset(_ path: String) -> Bool { (try? file.open(path)).map { file.close($0); return true } ?? false }

        // `read_file`: the version, the image type, and `_parse_metadata_group` of the four groups (a group's datasets by
        // name; a dataset child is one JSON). Only `Operations` and `Displays` are read below; the other two are parsed so a
        // bad entry refuses the file as it raises in RosettaSciIO.
        var groups: [String: [String: Entry]] = [:]
        for name in ["Displays", "Operations", "SharedProperties", "Features"] where file.exists("/" + name) {
            var entries: [String: Entry] = [:]
            for child in file.children(of: "/" + name) {
                let path = "/\(name)/\(child)"
                if isDataset(path) {
                    entries[child] = Entry(path: path, isGroup: false, value: try json(path))
                } else {
                    var sub: [String: Any] = [:]
                    for leaf in file.children(of: path) { sub[leaf] = try json(path + "/" + leaf) }
                    entries[child] = Entry(path: path, isGroup: true, value: sub)
                }
            }
            groups[name] = entries
        }
        let images = file.children(of: "/Data/Image")
        let spectrumStream = file.exists("/Data/Image") && file.exists("/Data/SpectrumImage")

        // `_parse_image_display`, SpectrumStream files only: image id -> label.
        var labels: [String: (text: String, source: String)] = [:]
        if spectrumStream {
            // `int(self.version)`, only here.
            guard let versionText = file.readString("/Version"),
                  let version = (try? JSONSerialization.jsonObject(with: Data(versionText.utf8))) as? [String: Any],
                  let versionNumber = Self.pythonInt(version["version"]) else {
                throw refuse("its Version is not an integer")
            }
            if versionNumber >= 11 {
                guard let display = groups["Displays"]?["ImageDisplay"], let displays = display.value as? [String: Any] else {
                    throw refuse("no Displays/ImageDisplay")
                }
                // A dataset's JSON object iterates in its written order in Python, which JSONSerialization does not keep.
                guard display.isGroup else { throw refuse("Displays/ImageDisplay is a dataset, not a group (unsupported here)") }
                for key in displays.keys.sorted() {
                    guard let v = displays[key] as? [String: Any] else { throw refuse("Displays/ImageDisplay/\(key) is not an object") }
                    guard v.keys.contains("data") else { continue }
                    guard let data = v["data"] as? String, file.exists(data),
                          let target = try json(data) as? [String: Any], let dataPath = target["dataPath"] as? String,
                          let id = v["id"] as? String else { throw refuse("Displays/ImageDisplay/\(key) does not lead to a dataPath and an id") }
                    labels[Self.lastComponent(dataPath)] = (id, "/Displays/ImageDisplay/\(key).id (rsciio _parse_image_display, version >= 11)")
                }
            } else {
                let group = "/Presentation/Displays/ImageDisplay"
                guard file.exists(group) else { throw refuse("no Presentation/Displays/ImageDisplay") }
                for key in file.children(of: group) {
                    guard let v = try json(group + "/" + key) as? [String: Any], let dataPath = v["dataPath"] as? String,
                          let label = (v["display"] as? [String: Any])?["label"] as? String else {
                        throw refuse("\(group)/\(key) lacks dataPath or display.label")
                    }
                    labels[Self.lastComponent(dataPath)] = (label, "\(group)/\(key).display.label (rsciio _parse_image_display, version < 11)")
                }
            }
        }

        // `_read_image` per image, in name order, one name carried across images.
        var carried: (text: String, source: String)?
        var out: [String: Title] = [:]
        for id in images {
            let group = "/Data/Image/" + id
            guard let om = (try? JSONSerialization.jsonObject(with: file.readMetadataJSON(group: group, column: 0))) as? [String: Any] else {
                throw refuse("the metadata of image \(id) is not a JSON object")
            }
            // `_get_detector_information`: the image's own Detectors (the four merged groups hold no such key).
            var information: Any?
            var informationKey = ""
            if let binary = om["BinaryResult"] {
                guard let binary = binary as? [String: Any] else { throw refuse("BinaryResult of image \(id) is not an object") }
                if let index = binary["DetectorIndex"], !(index is NSNull) {
                    guard let text = pythonFormat(index) else { throw refuse("DetectorIndex of image \(id) is not an integer or string") }
                    informationKey = "Detector-" + text
                }
            } else {
                informationKey = "Detector-0"
            }
            if !informationKey.isEmpty {
                guard let detectors = om["Detectors"] as? [String: Any], let entry = detectors[informationKey] else {
                    throw refuse("image \(id) names \(informationKey), which its Detectors lack")
                }
                information = entry
            }
            do {
                let name = try Self.detectorName(id: id, operations: groups["Operations"], refuse: refuse)
                carried = name
            } catch is Fallback {
                if let information {
                    guard let entry = information as? [String: Any], let name = entry["DetectorName"] else {
                        throw refuse("Detectors.\(informationKey) of image \(id) has no DetectorName")
                    }
                    guard let text = name as? String else { throw refuse("Detectors.\(informationKey).DetectorName of image \(id) is not a string") }
                    carried = (text, "Data/Image/\(id)/Metadata[0].Detectors.\(informationKey).DetectorName (rsciio DetectorInformation)")
                }
            }
            if let label = labels[id] {
                out[id] = Title(text: label.text, source: label.source)
            } else if let carried {
                out[id] = Title(text: carried.text, source: carried.source)
            } else {
                out[id] = Title(text: nil, source: "")
            }
        }
        byImage = out
    }

    /// `_get_detector_name(id)`: throws `Fallback` where Python raises KeyError (caught by `_read_image`).
    private static func detectorName(id: String, operations: [String: Entry]?,
                                     refuse: (String) -> FormatoReadError) throws -> (text: String, source: String) {
        guard let operations else { throw Fallback() }
        func lookup(_ entry: [String: Any], _ key: String) throws -> Any {
            guard let value = entry[key] else { throw Fallback() }
            return value
        }
        func contains(_ entry: [String: Any], _ key: String) throws -> Bool {   // Python's `id in entry[key]` on a string
            guard let text = try lookup(entry, key) as? String else { throw refuse("an Operations entry's \(key) is not a string") }
            return text.range(of: id, options: .literal) != nil
        }
        func mode(_ value: Any) -> String { (value as? String) == "true" ? "iDPC" : "dDPC" }
        for kind in kinds {
            guard let operation = operations[kind] else { continue }
            let path = operation.path
            guard operation.isGroup, let entries = operation.value as? [String: Any] else {
                throw refuse("Operations/\(kind) is not a group of entries (unsupported here)")
            }
            for key in entries.keys.sorted() {
                guard let entry = entries[key] as? [String: Any] else { throw refuse("\(path)/\(key) is not an object") }
                let at = "\(path)/\(key)"
                switch kind {
                case "CameraInputOperation":
                    if try contains(entry, "dataPath") {
                        guard let name = try lookup(entry, "cameraName") as? String else { throw refuse("\(at).cameraName is not a string") }
                        return (name, "\(at).cameraName (rsciio _get_detector_name)")
                    }
                case "StemInputOperation":
                    if try contains(entry, "dataPath") {
                        guard let name = try lookup(entry, "detector") as? String else { throw refuse("\(at).detector is not a string") }
                        return (name, "\(at).detector (rsciio _get_detector_name)")
                    }
                case "SurfaceReconstructionOperation":
                    if entry.keys.contains("unfilteredDataPath"), try contains(entry, "unfilteredDataPath") {
                        return (mode(try lookup(entry, "integrationMode")), "\(at).integrationMode (rsciio _get_detector_name, unfilteredDataPath)")
                    }
                    if try contains(entry, "dataPath") {
                        var name = mode(try lookup(entry, "integrationMode"))
                        if (try lookup(entry, "enableFilter") as? String) == "true" { name = "Filtered " + name }
                        return (name, "\(at).integrationMode, enableFilter (rsciio _get_detector_name, dataPath)")
                    }
                case "MathematicsOperation":
                    if try contains(entry, "dataPath") {
                        let outputs = try lookup(entry, "outputs")
                        let first: Any
                        if let list = outputs as? [Any] {
                            guard let head = list.first else { throw refuse("\(at).outputs is empty") }   // IndexError
                            first = head
                        } else if outputs is [String: Any] {
                            throw Fallback()   // a dict indexed by 0: KeyError
                        } else {
                            throw refuse("\(at).outputs is not a list")
                        }
                        guard let output = first as? [String: Any] else { throw refuse("\(at).outputs[0] is not an object") }
                        let index = try lookup(output, "inputIndex") as? String
                        if index == "0" { return ("A-C", "\(at).outputs[0].inputIndex (rsciio _get_detector_name)") }
                        if index == "1" { return ("B-D", "\(at).outputs[0].inputIndex (rsciio _get_detector_name)") }
                    }
                case "DpcOperation":
                    if try contains(entry, "dataPath") { return ("DPC", "\(at) (rsciio _get_detector_name)") }
                case "IntegrationOperation":
                    if try contains(entry, "dataPath") { return ("DCFI", "\(at) (rsciio _get_detector_name)") }
                default:   // FftOperation
                    if try contains(entry, "imageOutputPath") { return ("Half FFT", "\(at).imageOutputPath (rsciio _get_detector_name)") }
                }
            }
        }
        return ("Unrecognized_image_signal", "/Operations (no entry names the image; rsciio _get_detector_name)")
    }

    /// Python's `int(x)` for a JSON string or integer: surrounding whitespace allowed, ASCII digits, an optional sign.
    private static func pythonInt(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return Int(exactly: n.doubleValue.rounded(.towardZero)) }
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Python's `path.split("/")[-1]`.
    private static func lastComponent(_ path: String) -> String {
        String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    }
}
