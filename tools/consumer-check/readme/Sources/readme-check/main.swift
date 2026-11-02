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
import FormatoEMD

let velox = try VeloxImageSignals(path: "Tests/FormatoEMDTests/Fixtures/velox-titles-v6-image.emd")
for image in velox.images {
    let signal = try velox.signal(image).load()            // the stored type, RosettaSciIO's title
    print(signal.title, signal.data.dataType, signal.data.shape)
}

let options = VeloxSpectrumImageOptions(rebinEnergy: 1)
let spectrumImages = try VeloxSpectrumImageSignals(path: "Tests/FormatoEMDTests/Fixtures/velox-spectrum-image/si-planted-v11.emd",
                                                   options: options)
for signal in spectrumImages.signals {
    print(signal.title, signal.signalType, signal.data.dataType, signal.data.shape)
}
check(!velox.images.isEmpty, "block 2: the Velox file has \(velox.images.count) image(s)")
check(!spectrumImages.signals.isEmpty, "block 2: the spectrum-image file has \(spectrumImages.signals.count) signal(s)")

// README block 3
import FormatoTIFF

let tiff = try TIFFSignals(path: "Tests/FormatoTIFFTests/Fixtures/planted/fei-helios.tif")
for n in tiff.series.indices {
    let signal = try tiff.signal(series: n).load()
    print(signal.title, signal.data.dataType, signal.data.shape, signal.axes.map(\.units))
}
check(!tiff.series.isEmpty, "block 3: the TIFF file has \(tiff.series.count) series")

// README block 4 (the block opens "scan.h5": run it in a scratch folder where scan.h5 is the pinned py4DSTEM-written fixture)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("readme-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
try FileManager.default.copyItem(at: testsFolder.appendingPathComponent("FormatoHDF5Tests/Fixtures/4d/float32.h5"),
                                 to: scratch.appendingPathComponent("scan.h5"))
guard FileManager.default.changeCurrentDirectoryPath(scratch.path) else { print("readme-check: cannot enter scratch"); exit(2) }

import FormatoHDF5

let cube = try HDF5Datacube(path: "scan.h5", datasetPath: "/cube_root/cube/data")
let frame = try cube.read(start: [0, 0, 0, 0], count: [1, 1, cube.shape[2], cube.shape[3]])
let signal = cube.signal // lazy; signal.load() reads the complete cube
check(cube.shape.count == 4 && frame.bytes.count == cube.shape[2] * cube.shape[3] * 4, "block 4: the HDF5 datacube has shape \(cube.shape)")
_ = signal

// README block 5 (needs `peaks`: one array per scan position; runs in the same scratch folder)
let peaks = (0..<4).map { [BraggPeak(qx: Double($0) + 0.5, qy: 2, intensity: 1)] }
let shape = BraggGridShape(rows: 2, columns: 2), detector = BraggGridShape(rows: 256, columns: 256)
try BraggVectorsEMD.write(peaks: peaks, scan: shape, detector: detector,
                          calibration: BraggCalibration(qPixelSize: 0.01, qPixelUnits: "A^-1"),
                          to: URL(fileURLWithPath: "vectors.h5"), sourcePath: "scan.h5") // never over the source
let vectors = try BraggVectorsEMD.read(path: "vectors.h5") // py4DSTEM.read(...) opens the same file
_ = vectors
check(FileManager.default.fileExists(atPath: "vectors.h5"), "block 5: the BraggVectors file was written and read back")

print("readme-check: all five README blocks ran")
