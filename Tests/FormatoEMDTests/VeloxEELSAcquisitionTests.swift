//
//  VeloxEELSAcquisitionTests.swift
//  The beam energy and the angles of a Velox EELS spectrum image, as `AcquisitionMetadata` from each EELS group's own metadata.
//  File: Fixtures/eels (tools/velox-eels/pins.py: planted with h5py, then read by RosettaSciIO 049e7d70 and pyEELSMODEL eed9f072).
//  RosettaSciIO maps nothing for an EELS spectrum image (the script asserts it), so the signals stay its; the beam energy is
//  exact against the mapping RosettaSciIO gives the EDS signal of the same file and against pyEELSMODEL's E0, the collection
//  semi-angle against pyEELSMODEL's beta (radians, here × 1e3 to mrad), the convergence semi-angle against the planted value.
//

import Foundation
import Testing
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    @Suite struct VeloxEELSAcquisitionTests {
        static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/eels")

        struct Pins: Decodable {
            struct Bits: Decodable { let value: Double; let bits: String }
            struct Rosetta: Decodable { let eelsSignals: Int; let edsBeamEnergyKv: Bits }
            struct Cube: Decodable { let beamVoltageV: Int; let collectionAngleBeginRad: Bits; let collectionAngleEndRad: Bits }
            struct Planted: Decodable { let groups: [String]; let beamConvergenceRad: Double; let energyOffsetsEv: [Double] }
            let file: String
            let rosettasciio: Rosetta
            let rosettasciioEelsEnergyOffsetsEv: [Double]
            let pyeelsmodel: [Cube]
            let planted: Planted
        }
        static func pins() throws -> Pins {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Pins.self, from: Data(contentsOf: dir.appendingPathComponent("velox-eels-pins.json")))
        }
        private func bits(_ x: Double) -> String { String(format: "%016llx", x.bitPattern) }

        @Test func testEachEELSGroupGivesItsOwnMetadataInTheSignalsOrder() throws {
            let pins = try Self.pins()
            let path = Self.dir.appendingPathComponent(pins.file).path
            let metadata = try VeloxEMDReader(path: path).eelsSpectrumImageMetadata()
            let eels = try VeloxSpectrumImageSignals(path: path).signals.filter { $0.signalType == "EELS" }
            #expect(metadata.count == pins.pyeelsmodel.count)
            #expect(eels.count == pins.rosettasciio.eelsSignals && eels.count == metadata.count)
            // As stored, to the bit: pyEELSMODEL's float() of the same strings.
            #expect(metadata.map { $0.collectionAngleEndRadians.map(bits) } == pins.pyeelsmodel.map { $0.collectionAngleEndRad.bits })
            #expect(metadata.map { $0.collectionAngleBeginRadians.map(bits) } == pins.pyeelsmodel.map { $0.collectionAngleBeginRad.bits })
            #expect(metadata.map(\.accelerationVoltageVolts) == pins.pyeelsmodel.map { Double($0.beamVoltageV) })
            #expect(metadata.allSatisfy { $0.beamConvergenceRadians == pins.planted.beamConvergenceRad })
            // Signal i and metadata i come from the same group: each group states its own energy offset and collection range.
            #expect(eels.map { $0.axes.last?.offset } == pins.rosettasciioEelsEnergyOffsetsEv)
            #expect(pins.rosettasciioEelsEnergyOffsetsEv == pins.planted.energyOffsetsEv)
        }

        @Test func testTheAppConventionAndAnAngleThatIsNotPositive() throws {
            let pins = try Self.pins()
            let m = try VeloxEMDReader(path: Self.dir.appendingPathComponent(pins.file).path).eelsSpectrumImageMetadata()[0]
            let app = AcquisitionMetadata.velox(eelsSpectrumImage: m, convention: .app)
            #expect(app.collectionAngleMrad == nil && app.convergenceAngleMrad == nil)
            #expect(app == AcquisitionMetadata.velox(spectrumImage: m, convention: .app))
            for stored in ["0", "-0.001", "nan"] {
                let json = #"{"Optics": {"BeamConvergence": "\#(stored)"}, "CustomProperties": {"EnergyFilter.CollectionAngleRange.End": {"type": "double", "value": "\#(stored)"}}}"#
                let zero = try VeloxMetadata.parse(jsonData: Data(json.utf8))
                #expect(zero.collectionAngleEndRadians != nil, "\(stored): read as stored")
                let a = AcquisitionMetadata.velox(eelsSpectrumImage: zero)
                #expect(a.collectionAngleMrad == nil && a.convergenceAngleMrad == nil, "\(stored)")
            }
        }

        @Test func testAcquisitionMetadataOfAnEELSSpectrumImage() throws {
            let pins = try Self.pins()
            let path = Self.dir.appendingPathComponent(pins.file).path
            let metadata = try VeloxEMDReader(path: path).eelsSpectrumImageMetadata()
            try #require(metadata.count == pins.pyeelsmodel.count)
            for (m, cube) in zip(metadata, pins.pyeelsmodel) {
                let a = AcquisitionMetadata.velox(eelsSpectrumImage: m)
                // RosettaSciIO's beam energy for the EDS signal of the same file, and pyEELSMODEL's E0 in kV.
                #expect(a.highTensionKV.map { bits($0.value) } == pins.rosettasciio.edsBeamEnergyKv.bits)
                #expect(a.highTensionKV?.value == Double(cube.beamVoltageV) / 1e3)
                #expect(a.collectionAngleMrad.map { bits($0.value) } == bits(cube.collectionAngleEndRad.value * 1e3))
                #expect(a.convergenceAngleMrad.map { bits($0.value) } == bits(pins.planted.beamConvergenceRad * 1e3))
                #expect(a.convergenceAngleMrad?.note
                        == "Optics.BeamConvergence in radians × 1e3; no published reader reads this field; read as stored in the Velox metadata")
            }
        }

        @Test func testTheEELSSignalsStayRosettaSciIOs() throws {
            // RosettaSciIO's EELS dictionaries hold only General and Signal: no beam energy or angle is added to the signals.
            let pins = try Self.pins()
            let signals = try VeloxSpectrumImageSignals(path: Self.dir.appendingPathComponent(pins.file).path).signals
            for s in signals where s.signalType == "EELS" {
                #expect(Set(s.metadata.keys) == ["General.title", "General.original_filename"])
            }
        }

        /// RosettaSciIO's public Velox EELS file, unzipped by tools/test.sh: three energy ranges of a Zebra detector, each stating
        /// "300000" V, BeamConvergence "0.02143377827928146" rad and a collection range ending at "0.0033435492928249842" rad.
        static let publicEELS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/rsciio-unzipped/emd/velox_EELS_EDS.zip/example_velox_EELS_EDS.emd")

        @Test(.enabled(if: FileManager.default.fileExists(atPath: publicEELS.path), "RosettaSciIO's public Velox EELS file is not unzipped"))
        func testThePublicEELSFile() throws {
            let metadata = try VeloxEMDReader(path: Self.publicEELS.path).eelsSpectrumImageMetadata()
            #expect(metadata.count == 3)
            for m in metadata {
                let a = AcquisitionMetadata.velox(eelsSpectrumImage: m)
                #expect(a.highTensionKV?.value == 300)
                #expect(a.collectionAngleMrad?.value == Double("0.0033435492928249842")! * 1e3)
                #expect(a.convergenceAngleMrad?.value == Double("0.02143377827928146")! * 1e3)
            }
        }

        @Test func testAFileWithoutEELSGivesNoneAndTheSpectrumImageGroupStatesNoRange() throws {
            let pins = try Self.pins()
            let path = Self.dir.appendingPathComponent(pins.file).path
            let si = try #require(try VeloxEMDReader(path: path).spectrumImageMetadata())
            #expect(si.collectionAngleEndRadians == nil && AcquisitionMetadata.velox(eelsSpectrumImage: si).collectionAngleMrad == nil)
            let plain = Self.dir.deletingLastPathComponent().appendingPathComponent("velox-spectrum-image/si-planted-v11.emd").path
            #expect(try VeloxEMDReader(path: plain).eelsSpectrumImageMetadata().isEmpty)
        }
    }
}
