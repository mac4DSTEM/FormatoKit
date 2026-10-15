import Testing
import Foundation
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    /// Step 3 (docs/registration-step-3.md §4, gate "planted literals"): the four planted files of
    /// `tools/step-3/make_velox_titles.py`, each image's title and stored type typed here by hand from the rules, without the
    /// pins; and stored values Float32 cannot hold read exactly.
    @Suite final class VeloxTitlesTests {
        private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

        private func read(_ name: String) throws -> [String: (title: String?, type: FormatoDataType, signal: FormatoSignal)] {
            let velox = try VeloxImageSignals(path: Self.fixtures.appendingPathComponent(name).path)
            var out: [String: (String?, FormatoDataType, FormatoSignal)] = [:]
            for image in velox.images {
                let s = try velox.signal(image).load()
                out[image.id] = (velox.title(of: image), s.data.dataType, s)
            }
            return out
        }

        /// Every Operations kind and branch, in RosettaSciIO's order; the KeyError fallback; the substring match.
        @Test func testOperationsKindsAndBranches() throws {
            let got = try read("velox-titles-v6-image.emd")
            let want: [String: (String, FormatoDataType)] = [
                "a01": ("BM-Ceta", .uint8), "a02": ("HAADF", .uint16), "a03": ("iDPC", .uint32), "a04": ("dDPC", .int8),
                "a05": ("Filtered iDPC", .int16), "a06": ("A-C", .int32), "a07": ("B-D", .int64), "a08": ("DPC", .uint64),
                "a09": ("DCFI", .float32), "a10": ("Half FFT", .float64), "a11": ("Unrecognized_image_signal", .uint16),
                "a12": ("DI-a12", .uint8), "b1": ("DF-S", .float32), "b12": ("DF-S", .int16),
            ]
            #expect(Set(got.keys) == Set(want.keys))
            for (id, (title, type)) in want {
                #expect(got[id]?.title == title, "\(id) title")
                #expect(got[id]?.type == type, "\(id) stored type")
                #expect(got[id]?.signal.title == title, "\(id) signal title")
                #expect(got[id]?.signal.metadata["General.title"]?.value.text == title, "\(id) General.title")
            }
        }

        /// No Operations: DetectorInformation, the carried name, and no title before any name.
        @Test func testDetectorInformationAndTheCarriedName() throws {
            let got = try read("velox-titles-v11-noops.emd")
            #expect(got["img-a"]?.title == nil)
            #expect(got["img-a"]?.signal.title == "")
            #expect(got["img-a"]?.signal.metadata["General.title"] == nil, "no title in RosettaSciIO's metadata")
            #expect(got["img-b"]?.title == "DF4-B")
            #expect(got["img-c"]?.title == "DF4-B", "carried from img-b")
            #expect(got["img-e"]?.title == "HAADF", "DetectorIndex as the JSON number 0")
        }

        /// The label maps of SpectrumStream files: Displays for version 11, Presentation for version 9.
        @Test func testTheLabelMaps() throws {
            let v11 = try read("velox-titles-v11-labels.emd")
            #expect(v11["c1"]?.title == "Si-K")
            #expect(v11["c2"]?.title == "DI-c2", "no display; the Presentation label is not read at version 11")
            let v9 = try read("velox-titles-v9-labels.emd")
            #expect(v9["d1"]?.title == "HAADF-label")
            #expect(v9["d2"]?.title == "HAADF2")
        }

        /// Stored values Float32 does not hold come back exactly: uint64 beyond 2^63, int64 below -2^62, float64 1e300.
        @Test func testStoredValuesAreExact() throws {
            let got = try read("velox-titles-v6-image.emd")
            let u = try #require(got["a08"]?.signal.data.bytes)
            let first = u.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
            #expect(first == 9_223_425_912_924_536_979 as UInt64, "a08 is the eighth image (seed 7): 2^63 + 49 (2^40 + 3)")
            let i = try #require(got["a07"]?.signal.data.bytes)
            let firstI = i.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: Int64.self)) }
            #expect(firstI == -4_611_686_379_204_640_978 as Int64, "a07 (seed 6): -(2^62 + 42 (2^33 + 5))")
            let d = try #require(got["a10"]?.signal.data.bytes)
            let second = d.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))) }
            #expect(second == 1e300)
        }
    }
}
