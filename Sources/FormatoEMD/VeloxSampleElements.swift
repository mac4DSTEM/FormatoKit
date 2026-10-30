//
//  VeloxSampleElements.swift
//  Role: The four file-level metadata groups of a Velox file as RosettaSciIO 049e7d70's `read_file` parses them
//        (`_parse_metadata_group`), and `Sample.elements` as RosettaSciIO's mapping gives it once HyperSpy applies it
//        (`_get_mapping(map_selected_element=True)` with `_convert_element_list`, through `hyperspy/io.py` `dict2signal`).
//        `_convert_element_list` indexes `d.keys()[0]`, which only HyperSpy's `DictionaryTreeBrowser` allows: its `keys()` is the
//        sorted list of the slugified keys (`slugify(key, valid_variable_name=True)`), so the entry taken is the first in that order.
//        Wherever Python raises (a key missing, a value without `.keys()`, `int()` refusing, an atomic number outside 1...119), the
//        read is refused, as HyperSpy's `load` raises. Pinned by tools/velox-elements/pins.py.
//

import Foundation
import FormatoCore

/// The children of `Displays`, `Operations`, `SharedProperties` and `Features`, as `_parse_metadata_group` reads them.
nonisolated enum VeloxFileGroups {
    /// A child of one of the four groups: a group's datasets by name (as `{name: json}`), or one dataset's JSON.
    struct Entry { let path: String; let isGroup: Bool; let value: Any }

    static let names = ["Displays", "Operations", "SharedProperties", "Features"]

    /// The groups the file has, each child parsed. Must run inside `HDF5Serial.run`. Throws `refuse(reason)` where RosettaSciIO raises:
    /// a group stored as a dataset, an entry that is not one variable-length string of JSON. (An empty dataset, where RosettaSciIO
    /// logs a warning and keeps what it read, is refused here too: the reader cannot tell it from a damaged one.)
    static func read(file: VeloxFile, refuse: (String) -> FormatoReadError) throws -> [String: [String: Entry]] {
        func json(_ path: String) throws -> Any {
            guard let text = file.readString(path) else { throw refuse("\(path) is not one variable-length string") }
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else {
                throw refuse("\(path) is not JSON")
            }
            return value
        }
        func isDataset(_ path: String) -> Bool { (try? file.open(path)).map { file.close($0); return true } ?? false }
        var groups: [String: [String: Entry]] = [:]
        for name in names where file.exists("/" + name) {
            // `_parse_metadata_group` on a dataset: `_get_keys_from_group` raises AttributeError.
            guard !isDataset("/" + name) else { throw refuse("/\(name) is a dataset, not a group") }
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
        return groups
    }
}

/// `Sample.elements` of a Velox single spectrum.
package nonisolated enum VeloxSampleElements {
    /// RosettaSciIO's `atomic_number2name` (`rsciio/utils/_elements.py`), 1 to 119, its spellings kept (112 is "Cp", 113 to 119 the
    /// placeholder names).
    static let symbols = ("H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr "
        + "Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg "
        + "Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg Bh Hs Mt Ds Rg Cp Uut Uuq Uup Uuh Uus Uuo Uue")
        .split(separator: " ").map(String.init)

    /// HyperSpy's `slugify(value, valid_variable_name=True)`: NFKD, non-ASCII dropped, ASCII punctuation dropped (not "_" or " "),
    /// stripped, spaces to "_", and "Number_" before a result that is not an identifier.
    package static func slugify(_ key: String) -> String {
        let ascii = key.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)
        let kept = ascii.filter { $0 == "_" || $0 == " " || CharacterSet.alphanumerics.contains($0) }
        var text = String(String.UnicodeScalarView(kept))
        text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        let isIdentifier = text.first.map { $0 == "_" || $0.isLetter } == true
        return isIdentifier ? text : "Number_" + text
    }

    /// The mapping's source key for this file's version: `int(self.version)` >= 11 reads `SharedProperties`, else `Operations`.
    static func settingsPath(version: Int) -> (group: String, entry: String) {
        version >= 11 ? ("SharedProperties", "EDSSpectrumQuantificationSettings") : ("Operations", "ImageQuantificationOperation")
    }

    /// `_convert_element_list` on what HyperSpy's `get_item` returns for the settings path. `value` is the parsed entry (a dict of
    /// the group's datasets, or one dataset's JSON). nil is never returned: Python returns a list or raises (`refuse`).
    static func convert(_ value: Any, path: String, refuse: (String) -> FormatoReadError) throws -> (elements: [String], source: String) {
        // `d.keys()[0]`: only a dict has `keys()`; HyperSpy sorts the slugified keys and leaves out those starting with "_". Keys
        // that slugify alike are one attribute whose values HyperSpy merges: refused here (no file has them).
        guard let settings = value as? [String: Any] else { throw refuse("\(path) has no keys() (it is not a group of entries)") }
        var bySlug: [String: String] = [:]
        for key in settings.keys {
            let slug = slugify(key)
            guard bySlug.updateValue(key, forKey: slug) == nil else { throw refuse("\(path) has two entries that read as \(slug) (unsupported here)") }
        }
        guard let first = bySlug.keys.filter({ !$0.hasPrefix("_") }).sorted().first, let key = bySlug[first], let entry = settings[key] else {
            throw refuse("\(path) has no entry (keys()[0])")
        }
        guard let inner = entry as? [String: Any] else { throw refuse("\(path)/\(key) has no keys() (it is not a JSON object)") }
        let source = "\(path)/\(key).elementSelection"
        // "elementSelection" in `_d.keys()`, absent: no element selected, [].
        let matches = inner.keys.filter { slugify($0) == "elementSelection" }
        guard !matches.isEmpty else { return ([], source) }
        guard matches.count == 1, let selection = inner[matches[0]] else {
            throw refuse("\(path)/\(key) has several keys that read as elementSelection (unsupported here)")
        }
        // `for atomic_number in atomic_number_list`: a list, a string (its characters), an empty object; anything else raises.
        let items: [Any]
        switch selection {
        case let list as [Any]: items = list
        case let text as String: items = text.unicodeScalars.map { String($0) }   // Python iterates code points
        // A dict iterates over its keys that do not slugify to "_..." (none: []); any such key gives a tuple, which int() refuses.
        case let object as [String: Any] where object.keys.allSatisfy({ slugify($0).hasPrefix("_") }): items = []
        default: throw refuse("\(source) is not a list or a string")
        }
        var out: [String] = []
        for item in items {
            if item is [Any] || item is [String: Any] { throw refuse("\(source) holds a list or an object (int() raises)") }
            guard let z = pythonIntValue(item) else { throw refuse("\(source): int() refuses \(item)") }
            guard z >= 1, z <= symbols.count else { throw refuse("\(source): \(z) is not in atomic_number2name") }
            out.append(symbols[z - 1])
        }
        return (out, source)
    }
}
