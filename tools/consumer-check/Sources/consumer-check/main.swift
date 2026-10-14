// The consumer check's body: public API only, against the committed fixtures. Prints one line per failed check and a summary
// `consumer-check summary: N checks, F failed`; exit 1 on any failure.
import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoHDF5

nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var failed = 0
func check(_ ok: @autoclosure () throws -> Bool, _ what: String) {
    checks += 1
    do { if try !ok() { failed += 1; print("FAIL  \(what)") } } catch { failed += 1; print("FAIL  \(what): \(error)") }
}

let tests = URL(fileURLWithPath: CommandLine.arguments[1])
let velox = tests.appendingPathComponent("FormatoEMDTests/Fixtures/velox-tiny.emd").path
let planted = tests.appendingPathComponent("FormatoDMTests/Fixtures/eels-planted.dm4").path
let demo = tests.appendingPathComponent("FormatoDMTests/Fixtures/demo-edx-tiny.dm4").path

// H1: no variable, the shipped library.
check(ProcessInfo.processInfo.environment["MAC4DSTEM_HDF5_PATH"] == nil, "MAC4DSTEM_HDF5_PATH is unset for this run")
check(FormatoHDF5Library.bundledLibraryPath != nil, "the shipped libhdf5 is found next to the consumer")

// FormatoEMD: the moved API SpectroKit 0.4.0 and the apps call.
check(VeloxEMDReader.isVeloxEMD(path: velox), "isVeloxEMD")
check(VeloxEMDReader.isVeloxFile(path: velox), "isVeloxFile")
do {
    let si: VeloxSpectrumImage = try VeloxEMDReader(path: velox).readSpectrumImage()
    let store: VeloxEventStore = si.eventStore
    check(store.geometry.ny == 3 && store.geometry.nx == 2 && store.geometry.channels == 8, "event store geometry")
    check(store.totalCounts == 11 && store.completeFrames == 2, "event store counts")
    check(store.summedSpectrum().reduce(0, +) == 11, "summed spectrum")
    check(store.rowOffsets.count == 7 && store.channelIndex.count == store.counts.count, "the CSR arrays")
    check(store.spectrum(pixel: 0) == [0, 3, 0, 0, 0, 0, 0, 0], "pixel 0 spectrum")
    check(si.streams.count == 2 && si.metadata.energyAxis != nil, "streams and metadata")
    let part = try VeloxEMDReader(path: velox).readSpectrumImage(frames: .range(1..<2))
    check(part.eventStore.totalCounts == 4, "frame selection")
    check((try? VeloxEMDReader(path: velox).readSpectrumImage(cancelled: { true })) == nil, "cancellation throws")
    do { _ = try VeloxEMDReader(path: velox).readSpectrumImage(cancelled: { true }) } catch { check(error is FormatoCancelled, "FormatoCancelled") }
} catch { check(false, "readSpectrumImage: \(error)") }
check(VeloxEMDReader.elementSelection(fromSettingsJSON: Data(#"{"elementSelection":[8,14]}"#.utf8)) == ["O", "Si"], "elementSelection")
check(HDF5Serial.run { 1 + 1 } == 2, "HDF5Serial.run")

// FormatoDM: the moved API.
do {
    let objects = try DM4Experiment.list(path: demo)
    check(!objects.isEmpty, "DM4Experiment.list")
    if let eds = objects.first(where: { $0.role == .eds }) {
        let cube: DM4EDSSpectrumImage = try DM4Experiment.readEDSSpectrumImage(path: demo, index: eds.index)
        check(cube.counts.count == cube.nx * cube.ny * cube.channels, "readEDSSpectrumImage")
        check(eds.eds != nil && eds.dataByteCount > 0 && eds.dataOffset > 0, "EDS object fields")
    } else { check(false, "the demo file has an EDS object") }
    let eels = try DM4Experiment.readEELSSpectrumImage(path: planted, index: 2)
    check(eels.nx == 3 && eels.ny == 2 && eels.channels == 5, "readEELSSpectrumImage")
    let tree = try DM4Experiment.tagTree(data: Data(contentsOf: URL(fileURLWithPath: tests.appendingPathComponent("FormatoDMTests/Fixtures/dm-tag65027-saved-with-DM.dm4").path)))
    check(!tree.numbers.isEmpty || !tree.strings.isEmpty, "tagTree")
} catch { check(false, "DM4Experiment: \(error)") }
do { _ = try DM4Experiment.list(path: "/nonexistent.dm4") } catch { check(error is DM4Error, "DM4Error") }

// The step-1 adapters and FormatoCore.
do {
    let dm = try DMFile(path: planted)
    let s: FormatoSignal = try dm.signal(index: 2).load()
    check(s.data.shape == [5, 2, 3] && s.axes[2].offset == -3.75, "DMFile signal")
    check(s.metadata["General.title"]?.provenance.source == "ImageList.2.Name", "metadata provenance")
    let slab = try dm.signal(index: 2).array.read(start: [1, 0, 1], count: [2, 2, 2])
    check(slab == (try s.data.slab(start: [1, 0, 1], count: [2, 2, 2])), "lazy slab = eager slab")
    let images = try VeloxImageSignals(path: tests.appendingPathComponent("FormatoEMDTests/Fixtures/velox-metadata-planted.emd").path)
    check(!images.images.isEmpty, "VeloxImageSignals")
} catch { check(false, "adapters: \(error)") }
check(FormatoUnits.convertScaleUnits(1.5e-9, units: "m", factor: 100)?.units == "nm", "FormatoUnits")
check(FormatoUnits.parse("µm")?.shortForm == "μm", "units parse")

print("consumer-check summary: \(checks) checks, \(failed) failed")
exit(failed == 0 ? 0 : 1)
