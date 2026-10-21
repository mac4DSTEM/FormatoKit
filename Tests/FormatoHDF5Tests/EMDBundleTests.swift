//
//  EMDBundleTests.swift
//  The EMD "scientific bundle" writers: the 4D datacube (EMDDatacubeWriter), the calibration group and the result maps
//  (HDF5WriteSession.writeEMD...), the new-file and pending-file mechanism (HDF5NewFile, HDF5PendingFile), and the session
//  additions they stand on (variable-length text, bool, createDataset, writeSlab).
//
//  Pinned to the first consumer's OWN output: Fixtures/emd-bundle/app-*.h5 are written by mac4DSTEM's writers (Core at
//  c47a2b7a, kits at the app's pins) run offline on fixed inputs (tools/emd-bundle/oracle, README in that folder). Each test
//  builds the same content through the kit and compares every object, attribute and dataset byte with the app's file (only
//  the UUID differs). h5py and py4DSTEM read the committed swift-*.h5 files (tools/emd-bundle/check.py -> check-result.json,
//  pinned here with each file's SHA-256).
//
//  Regenerating the swift-*.h5 fixtures: FORMATO_EMD_FIXTURE_DIR=<this Fixtures/emd-bundle folder> swift test -c release
//  --filter EMDBundleTests, then tools/emd-bundle/check.py (its docstring has the line) and commit with check-result.json.
//

import Foundation
import Testing
import CryptoKit
import FormatoCore
import FormatoHDF5

@Suite(.serialized) struct EMDBundleTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/emd-bundle")
    }
    private func app(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    /// Where a produced file goes: a fresh scratch folder, or the fixtures folder when regenerating and `fixture` is set (only
    /// the four swift-*.h5 files the committed check covers are written there).
    private func scratch(fixture: Bool = false) throws -> URL {
        if fixture, let injected = ProcessInfo.processInfo.environment["FORMATO_EMD_FIXTURE_DIR"] { return URL(fileURLWithPath: injected, isDirectory: true) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emd-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func isFixtureRun() -> Bool { ProcessInfo.processInfo.environment["FORMATO_EMD_FIXTURE_DIR"] != nil }
    private func cleanup(_ url: URL) {
        if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: url) }
    }

    /// Every object of `url` as the reader sees it, without the one attribute that differs by design.
    private func stable(_ url: URL) throws -> [String: Entry] {
        var out = try snapshot(url)
        out["/"]?.attrs["UUID"] = nil
        return out
    }
    private func expectSame(_ made: URL, _ appFile: URL, _ note: String = "") throws {
        let a = try stable(made), b = try stable(appFile)
        var differences: [String] = []
        for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
            differences.append("\(key): kit \(a[key].map { "\($0)" } ?? "absent") | app \(b[key].map { "\($0)" } ?? "absent")")
        }
        #expect(differences.isEmpty, "\(note) \(differences.joined(separator: "\n"))")
    }
    private func floats(_ array: FormatoArray) -> [Float] {
        array.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: The datacube

    /// The calibration the app's export wrote, after its own bin/crop re-reference (read off the app's file by h5py).
    private var cubeCalibration: EMDCalibration {
        EMDCalibration(qPixelSize: 0.04, qPixelUnits: "A^-1", rPixelSize: 0.5, rPixelUnits: "nm", qrFlip: true, qrRotation: 0.5,
                       qrRotationConvention: "py4DSTEM", qx0Mean: 1.875, qy0Mean: 2.5, ellipseA: 0.75, ellipseB: 0.625,
                       ellipseTheta: 0.3, probeSemiangle: 0.875)
    }
    private func cubeLayout(booleanStorage: EMDBooleanStorage = .uint8) throws -> (EMDDatacubeLayout, [Float]) {
        let reader = try HDF5Reader(url: app("app-datacube.h5"))
        let pixels = floats(try reader.readDataset("/datacube_root/datacube/data"))
        guard case .text(let derivation) = try reader.attribute("mac4dstem_derivation", of: "/datacube_root") else { fatalError("derivation") }
        let header = EMDFileHeader(authoringProgram: "mac4DSTEM", attributes: ["accelerating_voltage": .real(200)])
        return (EMDDatacubeLayout(shape: [4, 5, 8, 9], header: header, calibration: cubeCalibration, booleanStorage: booleanStorage,
                                  rootAttributes: ["mac4dstem_derivation": .text(derivation)]), pixels)
    }

    @Test func datacubeWrittenBandByBandEqualsTheAppsFile() throws {
        let dir = try scratch(fixture: true); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("swift-datacube.h5")
        let (layout, pixels) = try cubeLayout()
        let writer = try EMDDatacubeWriter(destination: out, layout: layout)
        let band = 2 * 5 * 8 * 9
        try writer.write(rows: 2, values: Array(pixels[0..<band]))
        #expect(writer.rowsWritten == 2)
        try writer.write(rows: 2, values: Array(pixels[band...]))
        try writer.publish()
        try expectSame(out, app("app-datacube.h5"))
        let read = try HDF5Reader(url: out).readDataset("/datacube_root/datacube/data")
        #expect(read.shape == [4, 5, 8, 9])
        #expect(floats(read).map(\.bitPattern) == pixels.map(\.bitPattern))
    }

    @Test func wholeCubeWriteEqualsTheAppsFileAndLeavesNoScratch() throws {
        let dir = try scratch(); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("whole.h5")
        let (layout, pixels) = try cubeLayout()
        try EMDDatacubeWriter.write(pixels, layout: layout, to: out)
        try expectSame(out, app("app-datacube.h5"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["whole.h5"])
    }

    @Test func defaultBooleanIsTheH5pyEnumAndNothingElseChanges() throws {
        let dir = try scratch(fixture: true); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("swift-datacube-default.h5")
        let (layout, pixels) = try cubeLayout(booleanStorage: .h5pyEnum)
        try EMDDatacubeWriter.write(pixels, layout: layout, to: out)
        let flip = "/datacube_root/metadatabundle/calibration/QR_flip"
        #expect(try HDF5Reader(url: out).datasetInfo(flip).type == .unsupported("enum"))
        #expect(try HDF5Reader(url: app("app-datacube.h5")).datasetInfo(flip).type == .numeric(.uint8))
        var made = try stable(out), pinned = try stable(app("app-datacube.h5"))
        made[flip] = nil; pinned[flip] = nil
        #expect(made == pinned)
    }

    @Test func wholeCubeWriteRefusesABadShapeBeforeAnyProduct() throws {
        let dir = try scratch(); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("bad.h5")
        for shape in [[2, 2, 2], [0, 2, 2, 2], [Int.max, 2, 2, 2], [1 << 40, 1 << 40, 1 << 40, 1 << 40]] {
            let layout = EMDDatacubeLayout(shape: shape, header: EMDFileHeader(authoringProgram: "test"))
            #expect(throws: HDF5FileError.self) { try EMDDatacubeWriter.write([0, 1], layout: layout, to: out) }
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func axesOfOneAreASingleZeroAndMissingCalibrationIsPixels() throws {
        let dir = try scratch(); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("tiny.h5")
        let layout = EMDDatacubeLayout(shape: [1, 2, 3, 1], header: EMDFileHeader(authoringProgram: "test"))
        try EMDDatacubeWriter.write((0..<6).map(Float.init), layout: layout, to: out)
        let reader = try HDF5Reader(url: out)
        let node = "/datacube_root/datacube"
        #expect(try reader.readDataset(node + "/dim0").doubles() == [0])
        #expect(try reader.readDataset(node + "/dim1").doubles() == [0, 1])
        #expect(try reader.readDataset(node + "/dim3").doubles() == [0])
        #expect(try reader.attribute("units", of: node + "/dim2") == .text("pixels"))
        #expect(try reader.attribute("name", of: node + "/dim3") == .text("Qy"))
        #expect(try reader.exists("/datacube_root/metadatabundle") == false)
        #expect(floats(try reader.readDataset(node + "/data")) == (0..<6).map(Float.init))
        #expect(try reader.attribute("units", of: node + "/data") == .text("pixel intensity"))
    }

    @Test func datacubeRefusalsAndAtomicity() throws {
        let dir = try scratch(); defer { cleanup(dir) }
        let layout = EMDDatacubeLayout(shape: [2, 1, 2, 2], header: EMDFileHeader(authoringProgram: "test"))
        // A destination that is the source, by a different spelling, is refused before anything is written.
        let source = dir.appendingPathComponent("source.h5")
        try Data("x".utf8).write(to: source)
        let alias = dir.appendingPathComponent("alias.h5")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        #expect(throws: HDF5FileError.destinationIsSource(alias.path)) {
            _ = try EMDDatacubeWriter(destination: alias, layout: layout, sourcePath: source.path)
        }
        #expect(try Data(contentsOf: source) == Data("x".utf8))
        // Bad layouts.
        #expect(throws: HDF5FileError.self) { _ = try EMDDatacubeWriter(destination: dir.appendingPathComponent("a.h5"),
            layout: EMDDatacubeLayout(shape: [2, 2, 2], header: EMDFileHeader(authoringProgram: "t"))) }
        #expect(throws: HDF5FileError.self) { _ = try EMDDatacubeWriter(destination: dir.appendingPathComponent("a.h5"),
            layout: EMDDatacubeLayout(shape: [2, 0, 2, 2], header: EMDFileHeader(authoringProgram: "t"))) }
        #expect(throws: HDF5FileError.self) { _ = try EMDDatacubeWriter(destination: dir.appendingPathComponent("a.h5"),
            layout: EMDDatacubeLayout(shape: [2, 1, 2, 2], header: EMDFileHeader(authoringProgram: "t"), rootName: "a/b")) }
        #expect(throws: HDF5FileError.self) { _ = try EMDDatacubeWriter(destination: dir.appendingPathComponent("a.h5"),
            layout: EMDDatacubeLayout(shape: [2, 1, 2, 2], header: EMDFileHeader(authoringProgram: "t"),
                                      rootAttributes: ["emd_group_type": .text("x")])) }
        // A band past the end, or of the wrong size, writes nothing; an incomplete cube does not publish; cancel removes all.
        let existing = dir.appendingPathComponent("existing.h5")
        try Data("old".utf8).write(to: existing)
        let writer = try EMDDatacubeWriter(destination: existing, layout: layout)
        #expect(throws: HDF5FileError.self) { try writer.write(rows: 3, values: [Float](repeating: 0, count: 12)) }
        #expect(throws: HDF5FileError.self) { try writer.write(rows: Int.max, values: []) }
        #expect(throws: FormatoArrayError.self) { try writer.write(rows: 1, values: [1, 2, 3]) }
        try writer.write(rows: 1, values: [1, 2, 3, 4])
        #expect(throws: HDF5FileError.self) { try writer.publish() }
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        writer.cancel()
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: writer.pending.scratch.path))
        // A cancellation between bands leaves the destination as it was.
        #expect(throws: FormatoCancelled.self) {
            try EMDDatacubeWriter.write([Float](repeating: 1, count: 8), layout: layout, to: existing, cancelled: { true })
        }
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        // A complete write replaces the item that was there; a file that appears in between is not overwritten.
        let racing = dir.appendingPathComponent("racing.h5")
        let late = try EMDDatacubeWriter(destination: racing, layout: layout)
        try late.write(rows: 2, values: [Float](repeating: 2, count: 8))
        try Data("appeared".utf8).write(to: racing)
        #expect(throws: HDF5FileError.self) { try late.publish() }
        #expect(!FileManager.default.fileExists(atPath: late.pending.scratch.path))
        #expect(try Data(contentsOf: racing) == Data("appeared".utf8))
        try EMDDatacubeWriter.write([Float](repeating: 3, count: 8), layout: layout, to: existing)
        #expect(floats(try HDF5Reader(url: existing).readDataset("/datacube_root/datacube/data")) == [Float](repeating: 3, count: 8))
    }

    @Test func datacubeIsChunkedOnePatternPerChunkAndCalibrationRefusesToMerge() throws {
        let dir = try scratch(); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("chunks.h5")
        let (layout, pixels) = try cubeLayout()
        try EMDDatacubeWriter.write(pixels, layout: layout, to: out)
        // The chunk shape is not visible through HDF5Reader; read it from the file's object header via h5py's pin in
        // check.py (swift-datacube.h5 chunks == (1, 1, 8, 9)); here, that a pattern slab reads back whole.
        #expect(floats(try HDF5Reader(url: out).readDataset("/datacube_root/datacube/data", start: [3, 4, 0, 0], count: [1, 1, 8, 9]))
            == Array(pixels[(3 * 5 + 4) * 72..<(3 * 5 + 5) * 72]))
        try HDF5AppendWriter.append(to: out) { session in
            #expect(throws: HDF5FileError.alreadyExists("/datacube_root/metadatabundle/calibration")) {
                try session.writeEMDCalibration(EMDCalibration(rPixelSize: 9), inRoot: "/datacube_root")
            }
        }
        // A pending file ends at the first failing body, and its scratch goes.
        struct Stop: Error {}
        let pending = try HDF5PendingFile(destination: dir.appendingPathComponent("p.h5"))
        #expect(throws: Stop.self) { try pending.append { _ in throw Stop() } }
        #expect(throws: HDF5FileError.self) { try pending.append { _ in } }
        #expect(throws: HDF5FileError.self) { try pending.publish() }
        #expect(!FileManager.default.fileExists(atPath: pending.scratch.path))
        let empty = try HDF5PendingFile(destination: dir.appendingPathComponent("q.h5"))
        #expect(throws: HDF5FileError.invalidArgument("nothing was written to the pending file")) { try empty.publish() }
    }

    // MARK: The session sidecar: BraggVectors + calibration + maps

    private static let strainNode = "result_strain_exx_42329a38"
    private static let rgbaNode = "result_orientation_map_da0dee04"

    private func provenanceJSON(_ values: [String: String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
    }
    private func fullCalibration() -> EMDCalibration {
        let n = 12
        return EMDCalibration(qPixelSize: 0.02, qPixelUnits: "A^-1", rPixelSize: 0.5, rPixelUnits: "nm", qrFlip: true,
            qrRotation: 0.5, qrRotationConvention: "py4DSTEM", ellipseA: 1.5, ellipseB: 1.25, ellipseTheta: 0.3, probeSemiangle: 1.75,
            originMaps: EMDOriginMaps(shape: [3, 4], fittedQX: (0..<n).map { 12 + Double($0) * 0.125 },
                                      fittedQY: (0..<n).map { 13 + Double($0) * 0.0625 },
                                      measuredQX: (0..<n).map { 12.5 + Double($0) * 0.25 },
                                      measuredQY: (0..<n).map { 13.5 + Double($0) * 0.125 }))
    }
    /// What the first consumer stamps on a map's group and metadata (its keys; the kit stores them verbatim).
    private func annotations(kind: String, name: String, units: String, storage: String, rowStep: Double?, columnStep: Double?,
                             pixelUnits: String?, provenance: [String: String], metadataStorage: Bool) -> EMDMapAnnotations {
        var group: [String: HDF5AttributeValue] = ["mac4dstem_kind": .text(kind), "mac4dstem_display_name": .text(name),
                                                   "mac4dstem_value_units": .text(units), "mac4dstem_storage": .text(storage)]
        if let rowStep { group["mac4dstem_pixel_size_row"] = .text(String(rowStep)) }
        if let columnStep { group["mac4dstem_pixel_size_column"] = .text(String(columnStep)) }
        if let pixelUnits { group["mac4dstem_pixel_units"] = .text(pixelUnits) }
        var metadata = ["kind": kind, "display_name": name, "value_units": units]
        if metadataStorage { metadata["storage"] = storage }
        if !provenance.isEmpty {
            group["mac4dstem_provenance"] = .text(provenanceJSON(provenance))
            metadata["provenance"] = provenanceJSON(provenance)
        }
        return EMDMapAnnotations(groupAttributes: group, metadataName: "mac4dstem", metadata: metadata)
    }
    private func strainMap() -> EMDScalarMap {
        EMDScalarMap(nodeName: Self.strainNode, width: 4, height: 3, values: (0..<12).map { Float($0) * 0.5 - 1 },
            axes: EMDMapAxes(rowStep: 0.5, columnStep: 0.75, units: "nm"),
            annotations: annotations(kind: "strain_exx", name: "Strain εxx", units: "%", storage: "scalar_f32", rowStep: 0.5,
                                     columnStep: 0.75, pixelUnits: "nm", provenance: ["method": "oracle", "bin": "2"], metadataStorage: false))
    }
    private func orientationMap() -> EMDRGBAMap {
        EMDRGBAMap(nodeName: Self.rgbaNode, width: 4, height: 3, rgba: (0..<48).map { UInt8($0 * 5 % 256) },
            axes: EMDMapAxes(rowStep: 0.5, columnStep: 0.5, units: "nm"),
            annotations: annotations(kind: "orientation_map", name: "Orientation", units: "rgb", storage: "rgba8", rowStep: nil,
                                     columnStep: nil, pixelUnits: nil, provenance: [:], metadataStorage: true))
    }
    private func appPeaks() -> [[BraggPeak]] {
        (0..<12).map { i in
            i % 5 == 4 ? [] : (0..<(i % 3 + 1)).map { k in
                let x = Float(2 + i) + Float(k) * 0.5, y = Float(3 + k) - Float(i) * 0.25
                return BraggPeak(qx: Double(x), qy: Double(y), intensity: Double(Float(100 + i * 10 + k)))
            }
        }
    }

    @Test func sidecarBuiltFromBraggVectorsAndAppendedBundleEqualsTheAppsFile() throws {
        let dir = try scratch(fixture: true); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("swift-sidecar.h5")
        let nodes = [Self.strainNode, Self.rgbaNode]
        let detection = provenanceJSON(["detector": "oracle", "sigma": "1.5"])
        try BraggVectorsEMD.write(
            peaks: appPeaks(), scan: BraggGridShape(rows: 3, columns: 4), detector: BraggGridShape(rows: 16, columns: 20),
            calibration: BraggCalibration(), to: out, convention: .appImageXY, authoringProgram: "mac4DSTEM",
            extraAttributes: { target in
                switch target {
                case .root: ["mac4dstem_session_schema": "7", "mac4dstem_min_reader_schema": "5",
                             "mac4dstem_result_nodes": nodes.joined(separator: "\n"), "mac4dstem_current_result": nodes.last!]
                case .braggVectors: ["mac4dstem_detection_provenance": detection]
                case .file: [:]
                }
            })
        // The session's full calibration replaces the scalar one the Bragg writer made; the maps join the root.
        try HDF5AppendWriter.append(to: out) { session in
            try session.writeEMDCalibration(fullCalibration(), inRoot: "/braggvectors_root", targetPath: "/braggvectors",
                                            booleanStorage: .uint8, replace: true)
            try session.writeEMDScalarMap(strainMap(), inRoot: "/braggvectors_root")
            try session.writeEMDRGBAMap(orientationMap(), inRoot: "/braggvectors_root")
        }
        try expectSame(out, app("app-sidecar.h5"))
        // The peaks themselves, bit for bit, in the app's axis convention.
        let made = try BraggVectorsEMD.read(path: out.path, convention: .appImageXY)
        let pinned = try BraggVectorsEMD.read(path: app("app-sidecar.h5").path, convention: .appImageXY)
        #expect(made.peaks == pinned.peaks)
        #expect(made.peakCount == pinned.peakCount && made.peakCount > 0)
        // Replacing a map keeps the rest of the file; an existing node without `replace` is refused and changes nothing.
        let work = try scratch(), copy = work.appendingPathComponent("copy.h5"); defer { cleanup(work) }
        try FileManager.default.copyItem(at: out, to: copy)
        let before = try Data(contentsOf: copy)
        #expect(throws: HDF5FileError.alreadyExists("/braggvectors_root/" + Self.strainNode)) {
            try HDF5AppendWriter.append(to: copy) { try $0.writeEMDScalarMap(strainMap(), inRoot: "/braggvectors_root") }
        }
        #expect(try Data(contentsOf: copy) == before)
        var changed = strainMap(); changed.values[0] = 99
        try HDF5AppendWriter.append(to: copy) { try $0.writeEMDScalarMap(changed, inRoot: "/braggvectors_root", replace: true) }
        let reader = try HDF5Reader(url: copy)
        #expect(floats(try reader.readDataset("/braggvectors_root/\(Self.strainNode)/data")).first == 99)
        #expect(try reader.exists("/braggvectors_root/\(Self.rgbaNode)/data"))
    }

    @Test func scientificBundleInANewFileEqualsTheAppsFile() throws {
        let dir = try scratch(fixture: true); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("swift-bundle.h5")
        let strain = EMDScalarMap(nodeName: Self.strainNode, width: 4, height: 3, values: (0..<12).map { Float($0) * 0.25 },
            axes: EMDMapAxes(rowStep: 0.5, columnStep: 0.5, units: "nm"),
            annotations: annotations(kind: "strain_exx", name: "Strain εxx", units: "%", storage: "scalar_f32", rowStep: 0.5,
                                     columnStep: 0.5, pixelUnits: "nm", provenance: ["m": "x"], metadataStorage: false))
        let rotation = EMDScalarMap(nodeName: "result_rotation_21ac415f", width: 4, height: 3, values: (0..<12).map { -Float($0) },
            axes: EMDMapAxes(rowStep: 0.5, columnStep: 0.5, units: "nm"),
            annotations: annotations(kind: "rotation", name: "Rotation", units: "deg", storage: "scalar_f32", rowStep: nil,
                                     columnStep: nil, pixelUnits: nil, provenance: [:], metadataStorage: false))
        let sourcePath = dir.appendingPathComponent("not-this.h5").path
        try HDF5NewFile.write(to: out, sourcePath: sourcePath) { session in
            // The app's bundle header has no UUID and no authoring_user.
            try session.writeEMDFileHeader(EMDFileHeader(authoringProgram: "mac4DSTEM", authoringUser: nil, uuid: nil))
            try session.createEMDRoot("scientific_bundle_root",
                                      attributes: ["mac4dstem_bundle_schema": .text("1"), "mac4dstem_bundle_fields": .text("strain_exx\nrotation")])
            var calibration = fullCalibration()
            calibration.qx0Mean = nil
            try session.writeEMDCalibration(calibration, inRoot: "/scientific_bundle_root", booleanStorage: .uint8)
            try session.writeEMDScalarMap(strain, inRoot: "/scientific_bundle_root")
            try session.writeEMDScalarMap(rotation, inRoot: "/scientific_bundle_root")
        }
        try expectSame(out, app("app-bundle.h5"))
        // Writing again replaces the file (a new-file write is not an append) and a failing body leaves it alone.
        let work = try scratch(), copy = work.appendingPathComponent("copy.h5"); defer { cleanup(work) }
        try FileManager.default.copyItem(at: out, to: copy)
        let before = try Data(contentsOf: copy)
        struct Boom: Error {}
        #expect(throws: Boom.self) { try HDF5NewFile.write(to: copy) { _ in throw Boom() } }
        #expect(try Data(contentsOf: copy) == before)
        try HDF5NewFile.write(to: copy) { try $0.writeEMDFileHeader(EMDFileHeader(authoringProgram: "second")) }
        #expect(try HDF5Reader(url: copy).children(of: "/").isEmpty)
        #expect(try HDF5Reader(url: copy).attribute("authoring_program", of: "/") == .text("second"))
        #expect(throws: HDF5FileError.destinationIsSource(copy.path)) {
            try HDF5NewFile.write(to: copy, sourcePath: copy.path) { _ in }
        }
    }

    @Test func mapsAndCalibrationRefuseWhatTheyCannotStore() throws {
        let dir = try scratch(); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("refusals.h5")
        try HDF5NewFile.write(to: out) { session in
            try session.createEMDRoot("r")
            #expect(throws: HDF5FileError.self) {
                try session.writeEMDScalarMap(EMDScalarMap(nodeName: "m", width: 2, height: 2, values: [1, 2, 3]), inRoot: "/r")
            }
            #expect(throws: HDF5FileError.self) {
                try session.writeEMDRGBAMap(EMDRGBAMap(nodeName: "m", width: 2, height: 2, rgba: [UInt8](repeating: 0, count: 15)), inRoot: "/r")
            }
            #expect(throws: HDF5FileError.self) {
                try session.writeEMDScalarMap(EMDScalarMap(nodeName: "a/b", width: 1, height: 1, values: [1]), inRoot: "/r")
            }
            #expect(throws: HDF5FileError.self) {
                try session.createEMDRoot("x", attributes: ["python_class": .text("Other")])
            }
            #expect(throws: HDF5FileError.self) {
                try session.writeEMDFileHeader(EMDFileHeader(authoringProgram: "p", attributes: ["UUID": .text("u")]))
            }
            // Origin maps whose counts disagree are left out; the scalars and means that exist are still written.
            try session.writeEMDCalibration(EMDCalibration(qPixelSize: 1, qx0Mean: 3,
                originMaps: EMDOriginMaps(shape: [2, 2], fittedQX: [1, 2, 3], fittedQY: [1, 2, 3, 4])), inRoot: "/r")
        }
        let reader = try HDF5Reader(url: out)
        let calibration = "/r/metadatabundle/calibration"
        #expect(try reader.exists(calibration + "/Q_pixel_size"))
        #expect(try reader.exists(calibration + "/qx0_mean"))
        #expect(try reader.exists(calibration + "/qx0") == false)
        #expect(try reader.exists(calibration + "/_target_paths") == false)
        #expect(try reader.exists("/r/m") == false)
        // Without a rotation there is no convention and no degrees; with one, degrees follow unless given.
        try HDF5AppendWriter.append(to: out) { session in
            try session.writeEMDCalibration(EMDCalibration(qrRotation: .pi / 2, qrRotationConvention: "c"), inRoot: "/r", replace: true)
        }
        #expect(try reader.readDataset(calibration + "/QR_rotation_degrees").doubles() == [Double.pi / 2 * 180 / Double.pi])
        #expect(try reader.readStrings(calibration + "/QR_rotation_convention") == ["c"])
    }

    // MARK: The session additions

    @Test func sessionVariableLengthTextBoolSlabAndCreateDataset() throws {
        let dir = try scratch(); defer { cleanup(dir) }
        let out = dir.appendingPathComponent("session.h5")
        try HDF5NewFile.write(to: out) { session in
            try session.setVariableLengthTextAttribute("a", on: "/", "héllo ✓")
            try session.setVariableLengthTextAttribute("a", on: "/", "replaced")
            try session.writeText("/g/t", "Q_pixel_units ångström")
            try session.writeText("/g/ascii", "plain", utf8: false)
            try session.writeBool("/g/flag", true)
            try session.createDataset("/g/cube", dataType: .uint16, shape: [4, 3], chunk: [2, 3])
            try session.writeSlab("/g/cube", start: [2, 0], array(.uint16, [2, 3], [UInt16]([1, 2, 3, 4, 5, 6])))
            #expect(throws: HDF5FileError.self) { try session.writeText("/g/t", "again") }
            try session.writeText("/g/t", "again", replace: true)
            #expect(throws: HDF5FileError.embeddedNUL("/g/n")) { try session.writeText("/g/n", "a\0b") }
            #expect(throws: HDF5FileError.self) { try session.writeText("/g/nonascii", "é", utf8: false) }
            #expect(throws: HDF5FileError.self) { try session.writeSlab("/g/cube", start: [3, 0], array(.uint16, [2, 3], [UInt16](repeating: 0, count: 6))) }
            #expect(throws: HDF5FileError.self) { try session.writeSlab("/g/cube", start: [0, 0], array(.uint8, [1, 1], [UInt8]([1]))) }
            #expect(throws: HDF5FileError.self) { try session.writeSlab("/g/cube", start: [0], array(.uint16, [1], [UInt16]([1]))) }
            #expect(throws: HDF5FileError.notFound("/g/missing")) { try session.writeSlab("/g/missing", start: [0], array(.uint16, [1], [UInt16]([1]))) }
            #expect(throws: HDF5FileError.self) { try session.writeSlab("/g", start: [0], array(.uint16, [1], [UInt16]([1]))) }
        }
        let reader = try HDF5Reader(url: out)
        #expect(try reader.attribute("a", of: "/") == .text("replaced"))
        #expect(try reader.readStrings("/g/t") == ["again"])
        #expect(try reader.datasetInfo("/g/t").type == .string(variableLength: true))
        #expect(try reader.datasetInfo("/g/flag").type == .unsupported("enum"))
        #expect(try reader.readDataset("/g/cube").bytes == array(.uint16, [4, 3], [UInt16]([0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6])).bytes)
    }

    // MARK: py4DSTEM and h5py read the committed Swift-written files

    @Test func py4DSTEMAndH5pyAgreeWithTheCommittedSwiftFiles() throws {
        if isFixtureRun() { return }
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("check-result.json"))) as! [String: Any]
        #expect(result["py4dstem_version"] as? String == "0.14.19")
        let files = result["files"] as! [String: [String: Any]]
        #expect(Set(files.keys) == ["swift-datacube.h5", "swift-datacube-default.h5", "swift-sidecar.h5", "swift-bundle.h5"])
        for (name, entry) in files {
            let digest = SHA256.hash(data: try Data(contentsOf: fixtures.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()
            #expect(entry["sha256"] as? String == digest, "\(name) changed after check.py ran: rerun it")
            for key in (entry["checks"] as! [String: Bool]).keys { #expect((entry["checks"] as! [String: Bool])[key] == true, "\(name): \(key)") }
            #expect((entry["checks"] as! [String: Bool]).count >= 3, "\(name): too few checks")
        }
        #expect(files["swift-datacube.h5"]?["py4dstem_class"] as? String == "DataCube")
        #expect((files["swift-sidecar.h5"]?["py4dstem_objects"] as? [String: String])?["braggvectors"] == "BraggVectors")
        #expect((files["swift-bundle.h5"]?["py4dstem_objects"] as? [String: String])?.values.allSatisfy { $0 == "RealSlice" } == true)
    }
}
