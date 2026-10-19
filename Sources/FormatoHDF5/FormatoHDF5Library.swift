//
//  FormatoHDF5Library.swift
//  Role: Where the libhdf5 that FormatoKit ships lives. HDF5 2.1.1 with libsz and libaec are three dynamic-framework
//        XCFrameworks (binary targets FormatoLibHDF5, FormatoLibSZ, FormatoLibAEC; tools/xcframework/build.sh), so Xcode embeds
//        them in an app and signs them with the app's own identity at archive time. The readers `dlopen` libhdf5 (they never
//        call it through a link); this is one more place for them to look, after the host's own copy.
//
//  The framework is FOUND, never assumed: a host that strips it must get "not here", never a crash.
//

import Foundation
import MachO

public nonisolated enum FormatoHDF5Library {
    /// The framework's name, and the name of its binary (the library's install name is
    /// `@rpath/FormatoLibHDF5.framework/Versions/A/FormatoLibHDF5`).
    package static let frameworkName = "FormatoLibHDF5"

    /// The path of the shipped libhdf5 (the binary inside `FormatoLibHDF5.framework`), or nil when the framework is not found.
    /// Looked for, in order: the image dyld already loaded (the framework is linked by FormatoHDF5, so this is the copy the
    /// process embeds, wherever the host put it), then the host's `Frameworks` folder and the folder of the executable
    /// (a SwiftPM-built tool or test keeps its frameworks beside the executable).
    public static var bundledLibraryPath: String? {
        if let loaded = loadedImagePath() { return loaded }
        var directories: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL { directories.append(frameworks) }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            directories.append(executable.appendingPathComponent("../Frameworks").standardized)
            directories.append(executable)
        }
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent())
        for directory in directories {
            let path = directory.appendingPathComponent("\(frameworkName).framework/\(frameworkName)").path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func loadedImagePath() -> String? {
        let suffix = "/\(frameworkName).framework/Versions/A/\(frameworkName)"
        let alternate = "/\(frameworkName).framework/\(frameworkName)"
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if path.hasSuffix(suffix) || path.hasSuffix(alternate) { return path }
        }
        return nil
    }
}
