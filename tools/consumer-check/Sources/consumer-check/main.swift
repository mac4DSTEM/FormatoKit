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
// 0.0.3: the five members SpectroKit's tests read, each flag at both values (negative controls), over every stream.
do {
    let tiny = try VeloxEMDReader(path: velox).readSpectrumImage()
    check(tiny.streamCount == 2 && tiny.streams.map(\.id).count == 2 && tiny.eventStore.pixelCount == 6, "streamCount, stream ids, pixelCount")
    check(tiny.eventStore.streamsAgreeOnCoverage, "streamsAgreeOnCoverage true when the streams end together")
    check(!tiny.energyCalibrationAgrees, "energyCalibrationAgrees false on two calibrations")
    let flags = try VeloxEMDReader(path: tests.appendingPathComponent("FormatoEMDTests/Fixtures/velox-flags-planted.emd").path).readSpectrumImage()
    check(flags.streams.map(\.id) == ["s0", "s1"] && flags.eventStore.pixelCount == 4, "stream ids in name order")
    check(!flags.eventStore.streamsAgreeOnCoverage, "streamsAgreeOnCoverage false when a later stream stops early")
    check(flags.energyCalibrationAgrees, "energyCalibrationAgrees true on one calibration")
} catch { check(false, "0.0.3 members: \(error)") }
// 0.0.3: the Detectors entries in the written order, as RosettaSciIO (SpectroKit's planted file; the index order gave 0.01 / -0.5).
do {
    let order = try VeloxEMDReader(path: tests.appendingPathComponent("FormatoEMDTests/Fixtures/velox-stream-axis-order.emd").path).readSpectrumImage()
    check(order.metadata.energyAxis?.offsetKeV == -1.9 && order.metadata.energyAxis?.scaleKeV == 0.02, "energy axis from the first detector written")
    check(order.metadata.detectors.map(\.index) == [0, 10, 2], "detectors in the written order")
} catch { check(false, "detector order: \(error)") }
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
    // RosettaSciIO raises on the moved metadata fixture (KeyError 'Scan'); since step 3 VeloxImageSignals refuses it too.
    check((try? VeloxImageSignals(path: tests.appendingPathComponent("FormatoEMDTests/Fixtures/velox-metadata-planted.emd").path)) == nil,
          "VeloxImageSignals refuses a file RosettaSciIO raises on")
    // Step 3: the stored type and RosettaSciIO's title through the public API (planted file, registration step 3 §4).
    let titled = try VeloxImageSignals(path: tests.appendingPathComponent("FormatoEMDTests/Fixtures/velox-titles-v6-image.emd").path)
    check(titled.images.count == 14, "VeloxImageSignals lists the images")
    if let a08 = titled.images.first(where: { $0.id == "a08" }) {
        let s = try titled.signal(a08).load()
        check(s.data.dataType == .uint64 && s.title == "DPC" && titled.title(of: a08) == "DPC", "stored type and title")
    } else { check(false, "the planted title file lists a08") }
} catch { check(false, "adapters: \(error)") }
check(FormatoUnits.convertScaleUnits(1.5e-9, units: "m", factor: 100)?.units == "nm", "FormatoUnits")
check(FormatoUnits.parse("µm")?.shortForm == "μm", "units parse")

print("consumer-check summary: \(checks) checks, \(failed) failed")
exit(failed == 0 ? 0 : 1)
