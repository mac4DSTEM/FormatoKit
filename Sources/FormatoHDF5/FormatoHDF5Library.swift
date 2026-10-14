//
//  FormatoHDF5Library.swift
//  Role: Where the libhdf5 that FormatoKit ships lives (docs/registration-step-1.md §5). HDF5 2.1.1 with libsz and libaec,
//        the three arm64 dylibs mac4DSTEM vendors (its commit 5ba712a0; sha256 in NOTICE), are a resource of this target,
//        so a package that depends on FormatoKit reads HDF5 files with nothing installed and no variable set. The readers
//        `dlopen` libhdf5 (they never link it); this is one more place for them to look, after the host's own copy.
//
//  The resource bundle is found WITHOUT `Bundle.module`, whose generated accessor traps when the bundle is missing: a
//  host that embeds its own libhdf5 and strips this bundle must still get "not here", never a crash.
//

import Foundation

public nonisolated enum FormatoHDF5Library {
    /// The name SwiftPM gives this target's resource bundle (`<package>_<target>`).
    package static let bundleName = "FormatoKit_FormatoHDF5"

    /// The path of the shipped `libhdf5.dylib`, or nil when the resource bundle is not found next to the host.
    /// Looked for where SwiftPM and Xcode put a resource bundle: the main bundle's resources (an app), the main bundle's
    /// own folder (a command-line tool built by SwiftPM: the bundle sits next to the executable), and the folder of the
    /// image that holds this code (a test bundle).
    public static var bundledLibraryPath: String? {
        for directory in candidateDirectories() {
            let bundle = directory.appendingPathComponent(bundleName + ".bundle")
            for sub in ["hdf5/libhdf5.dylib", "Contents/Resources/hdf5/libhdf5.dylib"] {
                let path = bundle.appendingPathComponent(sub).path
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    private final class Finder {}

    private static func candidateDirectories() -> [URL] {
        var out: [URL] = []
        if let resources = Bundle.main.resourceURL { out.append(resources) }
        out.append(Bundle.main.bundleURL)
        let own = Bundle(for: Finder.self)
        if let resources = own.resourceURL { out.append(resources) }
        out.append(own.bundleURL.deletingLastPathComponent())
        return out
    }
}
