// The consumer check's body: public API only, against the committed fixtures. Prints one line per failed check and a summary
// `consumer-check summary: N checks, F failed`; exit 1 on any failure.
import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoHDF5
import FormatoMRC
import FormatoTIFF

func need<T>(_ value: T?) throws -> T {
    guard let value else { throw FormatoReadError.unsupported("a value the check needs is missing") }
    return value
}
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
check(ProcessInfo.processInfo.environment["FORMATO_HDF5_PATH"] == nil, "FORMATO_HDF5_PATH is unset for this run")
check(FormatoHDF5Library.bundledLibraryPath != nil, "the shipped libhdf5 is found next to the consumer")

// FormatoEMD: the inherited API that consumers call.
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
// 0.0.3: the five members a consumer's tests read, each flag at both values (negative controls), over every stream.
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
// 0.0.3: the Detectors entries in the written order, as RosettaSciIO (a planted file; the index order gave 0.01 / -0.5).
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
    // Step 4: a spectrum image through the public API, defaults and two options (planted file, registration step 4 §4).
    let si = tests.appendingPathComponent("FormatoEMDTests/Fixtures/step4/sk-1stream-3frames.emd").path
    let eds = try VeloxSpectrumImageSignals(path: si).signals
    check(eds.count == 1 && eds[0].data.shape == [3, 4, 4096] && eds[0].data.dataType == .uint16 && eds[0].signalType == "EDS_TEM",
          "VeloxSpectrumImageSignals: the summed spectrum image")
    let frames = try VeloxSpectrumImageSignals(path: si, options: VeloxSpectrumImageOptions(sumFrames: false, rebinEnergy: 4, dataType: .float32)).signals
    check(frames.count == 1 && frames[0].data.shape == [3, 3, 4, 1024] && frames[0].axes.first?.name == "Time", "VeloxSpectrumImageOptions")
} catch { check(false, "adapters: \(error)") }
// Acquisition metadata (round 4): every format's reader and the FormatoCore pieces, public API only.
do {
    let acq = tests.appendingPathComponent("FormatoDMTests/Fixtures/acq-metadata/tem-image.dm4").path
    let object = try need(DM4Experiment.list(path: acq).first)
    let meta = AcquisitionMetadata.dm(object)
    check(meta.highTensionKV?.value == 300 && meta.magnification?.value == 50000 && meta.exposureS?.value == 0.25, "AcquisitionMetadata.dm")
    check(AcquisitionMetadata.dm(object, convention: .app).instrument?.value == "Tecnai", "AcquisitionMetadata.dm app convention")
    let mrc = tests.appendingPathComponent("FormatoMRCTests/Fixtures/acq-metadata/fei-128-sections.mrc").path
    check(try AcquisitionMetadata.mrc(path: mrc).magnification?.value == 14500, "AcquisitionMetadata.mrc")
    let tif = tests.appendingPathComponent("FormatoTIFFTests/Fixtures/acq-metadata/fei-helios.tif").path
    check(try AcquisitionMetadata.tiff(path: tif).highTensionKV?.value == 5, "AcquisitionMetadata.tiff")
    let emd = tests.appendingPathComponent("FormatoEMDTests/Fixtures/acq-metadata/velox-acquisition.emd").path
    let image = try need(VeloxEMDReader(path: emd).images().first { $0.id == "haadf" })
    check(image.detectorType == "ScanningDetector" && AcquisitionMetadata.velox(image).cameraLengthMM?.value == 150, "AcquisitionMetadata.velox")
    check(GuardedXML.document("<a><b>1</b></a>") != nil && GuardedXML.refusal("<a>") == .malformed, "GuardedXML")
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("formato-consumer-\(UUID().uuidString)")
    try FormatoFileWrite.write(Data([7]), to: out)
    check(try Data(contentsOf: out) == Data([7]), "FormatoFileWrite")
    try? FileManager.default.removeItem(at: out)
} catch { check(false, "acquisition metadata: \(error)") }
// Image readers (round 4): the MRC reader, the Velox TIFF calibration option and the Velox object rule, public API only.
do {
    let mrcImage = tests.appendingPathComponent("FormatoMRCTests/Fixtures/image-readers/f32-3x2.mrc").path
    let mrcSignal = try MRCReader(path: mrcImage).signal.load()
    check(mrcSignal.data.shape == [2, 3] && mrcSignal.axes.map(\.units) == ["nm", "nm"], "MRCReader")
    check(try MRCAppImage.read(path: mrcImage).x?.units == "Å", "MRCAppImage")
    let velox = tests.appendingPathComponent("FormatoTIFFTests/Fixtures/image-readers/velox-nm.tif").path
    let calibrated = try TIFFSignals(path: velox, options: TIFFReadOptions(veloxCalibration: true)).signal(series: 0)
    check(calibrated.axes.contains { $0.units == "nm" && $0.scale == 0.25 }, "TIFFReadOptions.veloxCalibration")
    check(TIFFVeloxCalibration.read(try TIFFFile(path: velox).directories[0]) != nil, "TIFFVeloxCalibration")
    let objects = try VeloxEMDReader(path: tests.appendingPathComponent("FormatoEMDTests/Fixtures/image-readers/velox-objects.emd").path).images()
    check(VeloxImageSelection.choose(objects)?.id == "c-haadf" && VeloxImageSelection.axes(of: objects[2]).x?.units == "m", "VeloxImageSelection")
} catch { check(false, "image readers: \(error)") }
// HDF5 root attributes (round 4): write, read and publish a small sidecar-style file, public API only.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-consumer-h5-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("a.h5")
    let (temporary, scratch) = HDF5RootAttributes.temporaryURL(for: destination)
    defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
    try HDF5RootAttributes.write([("identity", "1"), ("text", "Å")], to: temporary)
    try HDF5RootAttributes.publish(temporary, onto: destination, replacing: HDF5FileIdentity(ofItemAt: destination.path))
    let read = try HDF5RootAttributes.read(["identity", "text", "absent"], from: destination)
    check(read == ["identity": "1", "text": "Å"], "HDF5RootAttributes write, publish and read")
} catch { check(false, "HDF5RootAttributes: \(error)") }
// EMD scientific bundle and PNG text chunks (0.6.0): public API only.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-consumer-emd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cube = dir.appendingPathComponent("cube.h5")
    let layout = EMDDatacubeLayout(shape: [2, 2, 3, 3], header: EMDFileHeader(authoringProgram: "consumer-check"),
                                   calibration: EMDCalibration(qPixelSize: 0.5, qPixelUnits: "1/A", rPixelSize: 2, rPixelUnits: "nm"),
                                   rootAttributes: ["app_key": .text("kept")])
    try EMDDatacubeWriter.write((0..<36).map(Float.init), layout: layout, to: cube)
    let reader = try HDF5Reader(url: cube)
    check(try reader.readDataset("/datacube_root/datacube/data").shape == [2, 2, 3, 3], "EMDDatacubeWriter shape")
    check(try reader.attribute("app_key", of: "/datacube_root") == .text("kept"), "EMDDatacubeWriter caller attribute")
    let bundle = dir.appendingPathComponent("bundle.h5")
    try HDF5NewFile.write(to: bundle) { session in
        try session.writeEMDFileHeader(EMDFileHeader(authoringProgram: "consumer-check"))
        try session.createEMDRoot("bundle_root")
        try session.writeEMDCalibration(EMDCalibration(rPixelSize: 1), inRoot: "/bundle_root")
        try session.writeEMDScalarMap(EMDScalarMap(nodeName: "map", width: 2, height: 1, values: [1, 2]), inRoot: "/bundle_root")
        try session.writeEMDRGBAMap(EMDRGBAMap(nodeName: "rgba", width: 1, height: 1, rgba: [1, 2, 3, 4]), inRoot: "/bundle_root")
    }
    check(try HDF5Reader(url: bundle).exists("/bundle_root/map/metadatabundle/metadata") && HDF5Reader(url: bundle).exists("/bundle_root/rgba/data"), "EMD maps")
    let png = try FormatoPNG.encode(width: 2, height: 1, format: .gray8, pixels: Data([1, 2]), text: [PNGTextEntry(keyword: "Title", value: "t")])
    check(try FormatoPNG.textEntries(in: png) == [PNGTextEntry(keyword: "Title", value: "t")], "FormatoPNG text round trip")
} catch { check(false, "EMD bundle and PNG: \(error)") }
check(FormatoUnits.convertScaleUnits(1.5e-9, units: "m", factor: 100)?.units == "nm", "FormatoUnits")
check(FormatoUnits.parse("µm")?.shortForm == "μm", "units parse")

print("consumer-check summary: \(checks) checks, \(failed) failed")
exit(failed == 0 ? 0 : 1)
