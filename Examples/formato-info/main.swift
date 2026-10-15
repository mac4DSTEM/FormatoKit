// formato-info: the first ten minutes with FormatoKit. Opens a DigitalMicrograph (.dm3, .dm4), Velox (.emd) or TIFF file
// and prints every signal it holds as RosettaSciIO would return it (for Velox: its images, then its spectrum images with
// RosettaSciIO's defaults, `VeloxSpectrumImageSignals`): title, signal type, stored type, shape, the axes with
// their units, the metadata with where each value came from, and one value read lazily. Public API only.
//
//     swift run formato-info <file> [<file> ...]
//
import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoTIFF

/// Every signal of the file, lazy (nothing is read until a slab is asked for); a signal FormatoKit refuses is its error.
func signals(of path: String) throws -> [Result<FormatoLazySignal, Error>] {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "dm3", "dm4":
        let dm = try DMFile(path: path)
        return dm.objects.map { object in Result { try dm.signal(index: object.index) } }
    case "emd":
        let velox = try VeloxImageSignals(path: path)
        let images = velox.images.map { image in Result { try velox.signal(image) } }
        // The spectrum images are eager (as RosettaSciIO's lazy=False); wrapped here so every signal prints the same way.
        let spectra: [Result<FormatoLazySignal, Error>]
        do {
            spectra = try VeloxSpectrumImageSignals(path: path).signals.map { s in
                .success(FormatoLazySignal(title: s.title, signalType: s.signalType, axes: s.axes, metadata: s.metadata,
                                           array: FormatoInMemoryArray(s.data)))
            }
        } catch { spectra = [.failure(error)] }
        return images + spectra
    case "tif", "tiff":
        let tiff = try TIFFSignals(path: path)
        return tiff.series.indices.map { n in Result { try tiff.signal(series: n) } }
    default:
        throw FormatoReadError.unsupported("\(path): not a .dm3, .dm4, .emd, .tif or .tiff file")
    }
}

func describe(_ s: FormatoLazySignal, _ n: Int) throws {
    let shape = s.array.shape
    print("signal \(n): \"\(s.title)\"\(s.signalType.isEmpty ? "" : " (\(s.signalType))"), \(s.array.dataType.rawValue) \(shape)")
    for a in s.axes {
        print("  axis \(a.name ?? "-"): \(a.size) x \(a.scale) \(a.units) from \(a.offset)\(a.navigate ? ", navigation" : "")")
    }
    for e in s.metadata.entries {
        print("  \(e.key) = \(e.value.text ?? e.value.number.map { "\($0)" } ?? "?")\(e.units.map { " \($0)" } ?? "")  [\(e.provenance.source)]")
    }
    // A lazy read of one element: the first of the array, in its stored type, as a Double.
    let first = try s.array.read(start: shape.map { _ in 0 }, count: shape.map { _ in 1 })
    print("  first value: \(first.doubles().first.map { "\($0)" } ?? "-")")
}

let paths = CommandLine.arguments.dropFirst()
if paths.isEmpty { print("usage: formato-info <file.dm4 | file.emd | file.tif> ..."); exit(2) }
var failed = false
for path in paths {
    print("== \(path)")
    do {
        for (n, s) in try signals(of: path).enumerated() {
            switch s {
            case .success(let signal): try describe(signal, n)
            case .failure(let error): print("signal \(n): refused: \(error.localizedDescription)")
            }
        }
    } catch {
        failed = true
        print("  refused: \(error.localizedDescription)")
    }
}
exit(failed ? 1 : 0)
