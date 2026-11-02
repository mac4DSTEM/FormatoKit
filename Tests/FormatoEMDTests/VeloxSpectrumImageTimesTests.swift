//
//  VeloxSpectrumImageTimesTests.swift
//  FormatoKit 0.11.0: the live and real times of a Velox spectrum image, and its optics and pixel size as `AcquisitionMetadata`.
//  Files: Fixtures/times (tools/velox-times/pins.py: planted with h5py, then read by RosettaSciIO 049e7d70). RosettaSciIO maps no
//  live or real time for a spectrum image (the script asserts it), so those are exact against the planted seconds; camera length,
//  magnification and beam energy are exact against the mapping RosettaSciIO returns; the pixel size is exact against its axis
//  scale after the unit conversion the axis went through.
//

import Foundation
import Testing
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    @Suite struct VeloxSpectrumImageTimesTests {
        static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/times")

        struct Pins: Decodable {
            struct Axis: Decodable { let name: String; let scaleBits: String; let units: String }
            struct Mapped: Decodable { let bits: String; let value: Double }
            struct Segment: Decodable { let name: String; let realTimeS: Double; let liveTimeS: Double; let enabled: Bool }
            struct Planted: Decodable {
                struct Size: Decodable { let width: Double; let height: Double }
                let pixelSizeM: Size; let cameraLengthM: Double; let stemMagnification: Double; let segments: [Segment]
            }
            struct File: Decodable { let file: String; let axes: [Axis]; let mapped: [String: Mapped]; let planted: Planted }
            let files: [File]
        }
        static func pins() throws -> [Pins.File] {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Pins.self, from: Data(contentsOf: dir.appendingPathComponent("velox-times-pins.json"))).files
        }
        private func bits(_ x: Double) -> String { String(format: "%016llx", x.bitPattern) }
        private func path(_ file: String) -> String { Self.dir.appendingPathComponent(file).path }

        @Test func testEnabledSegmentsGiveTheirTimesAndTheSharedPair() throws {
            let file = try #require(try Self.pins().first { $0.file == "si-times-planted.emd" })
            let m = try #require(try VeloxEMDReader(path: path(file.file)).spectrumImageMetadata())
            let enabled = file.planted.segments.filter(\.enabled)
            #expect(enabled.count == 3)
            // The disabled fourth segment is left out; the others are as the file stores them, to the bit.
            #expect(m.segmentTimes.map(\.name) == enabled.map(\.name))
            #expect(m.segmentTimes.map { $0.liveTimeSeconds.map(bits) } == enabled.map { bits($0.liveTimeS) })
            #expect(m.segmentTimes.map { $0.realTimeSeconds.map(bits) } == enabled.map { bits($0.realTimeS) })
            #expect(m.commonLiveTimeSeconds.map(bits) == bits(enabled[0].liveTimeS))
            #expect(m.commonRealTimeSeconds.map(bits) == bits(enabled[0].realTimeS))
        }

        @Test func testSegmentsThatDisagreeGiveNoCommonTime() throws {
            let file = try #require(try Self.pins().first { $0.file == "si-times-differ.emd" })
            let m = try #require(try VeloxEMDReader(path: path(file.file)).spectrumImageMetadata())
            let enabled = file.planted.segments.filter(\.enabled)
            #expect(m.segmentTimes.map { $0.liveTimeSeconds } == enabled.map { $0.liveTimeS })
            #expect(m.segmentTimes.map { $0.realTimeSeconds } == enabled.map { $0.realTimeS })
            #expect(m.commonLiveTimeSeconds == nil && m.commonRealTimeSeconds == nil)
        }

        @Test func testTheSignalsStayRosettaSciIOsAndAFileWithoutSpectrumImageMetadataGivesNil() throws {
            // The times are not in the signal metadata (that stays RosettaSciIO's); a file whose SI group has no Metadata gives nil.
            let md = try VeloxSpectrumImageSignals(path: path("si-times-planted.emd")).signals[0].metadata
            #expect(!md.keys.contains { $0.hasSuffix("live_time") || $0.hasSuffix("real_time") })
            let plain = Self.dir.deletingLastPathComponent().appendingPathComponent("velox-spectrum-image/si-planted-v11.emd").path
            #expect(try VeloxEMDReader(path: plain).spectrumImageMetadata() == nil)
        }

        @Test func testSpectrumImageMetadataExposesTheTimesAndTheOptics() throws {
            for file in try Self.pins() {
                let m = try #require(try VeloxEMDReader(path: path(file.file)).spectrumImageMetadata())
                let want = file.planted.segments
                #expect(m.superXDetectors.map(\.name) == want.map(\.name), "\(file.file)")
                #expect(m.superXDetectors.map { $0.liveTimeColumn0 } == want.map { $0.liveTimeS }, "\(file.file)")
                #expect(m.superXDetectors.map { $0.realTimeColumn0 } == want.map { $0.realTimeS }, "\(file.file)")
                #expect(m.cameraLengthMeters == file.planted.cameraLengthM && m.stemMagnification == file.planted.stemMagnification)
            }
        }

        @Test func testAcquisitionMetadataOfASpectrumImageEqualsRosettaSciIOsMapping() throws {
            for file in try Self.pins() {
                let m = try #require(try VeloxEMDReader(path: path(file.file)).spectrumImageMetadata())
                let a = AcquisitionMetadata.velox(spectrumImage: m)
                let camera = a.cameraLengthMM.map { bits($0.value) }, magnification = a.magnification.map { bits($0.value) }
                let energy = a.highTensionKV.map { bits($0.value) }
                #expect(camera == file.mapped["Acquisition_instrument.TEM.camera_length"]?.bits)
                #expect(magnification == file.mapped["Acquisition_instrument.TEM.magnification"]?.bits)
                #expect(energy == file.mapped["Acquisition_instrument.TEM.beam_energy"]?.bits)
                // The pixel size as stored, and, converted as the axis was, RosettaSciIO's axis scales (y: rows, x: columns).
                let size = try #require(a.pixelSize?.value)
                #expect(size.units == "m" && size.columns == file.planted.pixelSizeM.width && size.rows == file.planted.pixelSizeM.height)
                let y = try #require(file.axes.first { $0.name == "y" }), x = try #require(file.axes.first { $0.name == "x" })
                let rowScale = FormatoUnits.convertUnits(size.rows, from: size.units, to: y.units).map { bits($0) }
                let columnScale = FormatoUnits.convertUnits(size.columns, from: size.units, to: x.units).map { bits($0) }
                #expect(rowScale == y.scaleBits)
                #expect(columnScale == x.scaleBits)
            }
        }

        @Test func testPixelSizeOfAnImageEntryEqualsItsAxes() throws {
            let source = Self.dir.deletingLastPathComponent().appendingPathComponent("image-readers/velox-objects.emd").path
            let reader = VeloxEMDReader(path: source)
            let images = try VeloxImageSignals(path: source)
            var checked = 0
            for entry in try reader.images() {
                guard let size = AcquisitionMetadata.velox(entry).pixelSize?.value, let signal = try? images.signal(entry) else { continue }
                let axes = signal.axes
                guard axes.count >= 2 else { continue }
                // RosettaSciIO converts the x scale with its unit-picking rule (`_convert_scale_units`, by the image width) and the y
                // scale into x's unit: the same two steps from the stored numbers.
                guard case .converted(let columnScale, let unit) = FormatoUnits.scaleOutcome(size.columns, units: size.units, factor: entry.width) else {
                    Issue.record("no conversion for \(size)"); continue
                }
                let rows = FormatoUnits.convertUnits(size.rows, from: size.units, to: unit).map { bits($0) }
                #expect(unit == axes[axes.count - 1].units && bits(columnScale) == bits(axes[axes.count - 1].scale), "\(size) \(axes.map { ($0.scale, $0.units) })")
                #expect(rows == bits(axes[axes.count - 2].scale))
                #expect(AcquisitionMetadata.velox(entry, convention: .app).pixelSize == nil)
                checked += 1
            }
            #expect(checked >= 1)
        }
    }
}
