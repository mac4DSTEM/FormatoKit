// README check: the Swift code blocks of README.md, pasted verbatim (tools/consumer-check/run.sh verifies every line is still
// in the README), each run at top level with the repository's root as the working directory, as the README says. The only
// additions are the working directory, the argument and the assertions that each block produced something.
// Usage: readme-check <path of the repository's Tests folder>
import Foundation

guard CommandLine.arguments.count == 2 else { print("usage: readme-check <Tests folder>"); exit(2) }
let testsFolder = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard FileManager.default.changeCurrentDirectoryPath(testsFolder.deletingLastPathComponent().path) else {
    print("readme-check: cannot enter the repository root"); exit(2)
}
func check(_ ok: Bool, _ what: String) {
    guard ok else { print("readme-check: FAILED: \(what)"); exit(1) }
    print("readme-check: ok: \(what)")
}

// README block 1
import FormatoCore
import FormatoDM

let dm = try DMFile(path: "Tests/FormatoDMTests/Fixtures/eels-planted.dm4")
for object in dm.objects {
    do {
        let lazy = try dm.signal(index: object.index)      // nothing read yet
        print(lazy.title, lazy.array.dataType, lazy.array.shape, lazy.axes.map(\.units))
        let signal = try lazy.load()                       // the stored bytes, C order, little-endian
        print(signal.metadata["Acquisition_instrument.TEM.beam_energy"]?.provenance.source ?? "-")
    } catch {
        print("object \(object.index) refused:", error)    // a type FormatoKit does not read is refused by name
    }
}
check(dm.objects.count > 0, "block 1: the DM file lists \(dm.objects.count) object(s)")

// README block 2
import FormatoCore
import FormatoEMD

let velox = try VeloxImageSignals(path: "Tests/FormatoEMDTests/Fixtures/velox-titles-v6-image.emd")
for image in velox.images {
    let signal = try velox.signal(image).load()            // the stored type, RosettaSciIO's title
    print(signal.title, signal.data.dataType, signal.data.shape)
}

let options = VeloxSpectrumImageOptions(rebinEnergy: 1)
let spectrumImages = try VeloxSpectrumImageSignals(path: "Tests/FormatoEMDTests/Fixtures/step4/si-planted-v11.emd",
                                                   options: options)
for signal in spectrumImages.signals {
    print(signal.title, signal.signalType, signal.data.dataType, signal.data.shape)
}
check(!velox.images.isEmpty, "block 2: the Velox file has \(velox.images.count) image(s)")
check(!spectrumImages.signals.isEmpty, "block 2: the spectrum-image file has \(spectrumImages.signals.count) signal(s)")

// README block 3
import FormatoCore
import FormatoTIFF

let tiff = try TIFFSignals(path: "Tests/FormatoTIFFTests/Fixtures/planted/fei-helios.tif")
for n in tiff.series.indices {
    let signal = try tiff.signal(series: n).load()
    print(signal.title, signal.data.dataType, signal.data.shape, signal.axes.map(\.units))
}
check(!tiff.series.isEmpty, "block 3: the TIFF file has \(tiff.series.count) series")

print("readme-check: all three README blocks ran")
