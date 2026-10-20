// The consumer's acquisition-metadata readers, compiled unchanged (macTEM cb6e164, Sources/TEMCore/Data/AcquisitionMetadata*.swift)
// with stand-ins for what they import, and run on the generator's cases. Prints one JSON object: case name -> fields.
import Foundation

// Stand-ins for the consumer's other types the readers name (the pixel readers, CalibratedImage, DisplayFileName and
// VeloxImageReader are compiled unchanged too).
enum DM4Experiment {
    static func tagTree(data: Data) throws -> (numbers: [String: Double], strings: [String: String]) { throw TIFFImageReader.Refusal.truncated }
}
package struct FormatoCancelled: Error {}
package enum VeloxEMDError: Error {
    case libraryUnavailable, notVeloxFile, notVelox, cannotOpen
    package var errorDescription: String? { "\(self)" }
}
package enum VeloxImageElementType: String { case uint8, uint16, uint32, uint64, int8, int16, int32, int64, float32, float64 }
package struct VeloxDetectorInfo { package let index: Int; package let name: String; package let type: String }
package struct VeloxMetadata {
    package var detectors: [VeloxDetectorInfo] = []
    package var binaryResultDetectorIndex: Int?
    package var pixelSizeMeters: (width: Double, height: Double)?
    package var pixelUnit: String?
    package var pixelUnitY: String?
    package var offset: (x: Double, y: Double)?
    package var accelerationVoltageVolts: Double?
    package var binaryResultDetector: String?
    package var instrumentModel: String?
    package var acquisitionStartUnixTime: Double?
    package var dwellTimeSeconds: Double?
}
package struct VeloxImageInfo {
    package var id = "", detectorName = ""
    package var width = 2, height = 2, frameCount = 1
    package var elementType: VeloxImageElementType? = .uint16
    package var metadata = VeloxMetadata()
}
struct VeloxEMDReader {
    init(path: String) {}
    func images() throws -> [VeloxImageInfo] { [] }
    func readImageFrame(id: String, frame: Int) throws -> [Float] { [] }
}

func reading<V>(_ r: MetadataReading<V>?) -> Any {
    guard let r else { return NSNull() }
    return ["value": r.value, "note": r.note ?? NSNull(), "otherCopy": r.otherCopy ?? NSNull()] as [String: Any]
}

func dump(_ m: AcquisitionMetadata) -> [String: Any] {
    ["highTensionKV": reading(m.highTensionKV), "magnification": reading(m.magnification),
     "cameraLengthMM": reading(m.cameraLengthMM), "detector": reading(m.detector), "dwellUS": reading(m.dwellUS),
     "exposureS": reading(m.exposureS), "acquired": reading(m.acquired), "instrument": reading(m.instrument),
     "mode": reading(m.mode), "unread": m.unread.map(\.rawValue).sorted()]
}


func axis(_ a: ImageAxis?) -> Any {
    guard let a else { return NSNull() }
    return ["origin": a.origin, "scale": a.scale, "units": a.units] as [String: Any]
}

func dumpImage(_ i: CalibratedImage) -> [String: Any] {
    ["width": i.width, "height": i.height, "pixels": i.pixels.map { Double($0) }, "x": axis(i.x), "y": axis(i.y),
     "source": i.source, "voltage": i.voltage ?? NSNull(), "notes": i.notes]
}

/// The same image with every float as its bit pattern (UInt32 pixels, hex-string UInt64 axis fields), so inf, NaN, -0.0 and
/// every last bit of an axis survive the JSON.
func dumpImageBits(_ i: CalibratedImage) -> [String: Any] {
    func bits(_ a: ImageAxis?) -> Any {
        guard let a else { return NSNull() }
        return ["origin": String(a.origin.bitPattern, radix: 16), "scale": String(a.scale.bitPattern, radix: 16), "units": a.units] as [String: Any]
    }
    return ["width": i.width, "height": i.height, "pixels": i.pixels.map { Int($0.bitPattern) }, "x": bits(i.x), "y": bits(i.y),
            "source": i.source, "voltage": i.voltage ?? NSNull(), "notes": i.notes]
}

/// A Velox entry from the generator's JSON (keys: id, detectorName, detectorIndex, detectors, pixelSize, units, offset, ...).
func entry(_ c: [String: Any]) -> VeloxImageInfo {
    var e = VeloxImageInfo()
    e.id = c["id"] as? String ?? ""
    e.detectorName = c["detectorName"] as? String ?? ""
    e.width = c["width"] as? Int ?? 2
    e.height = c["height"] as? Int ?? 2
    e.frameCount = c["frameCount"] as? Int ?? 1
    e.elementType = (c["elementType"] as? String).map { VeloxImageElementType(rawValue: $0) } ?? .uint16
    e.metadata.binaryResultDetectorIndex = c["detectorIndex"] as? Int
    e.metadata.detectors = (c["detectors"] as? [[String: Any]] ?? []).map {
        VeloxDetectorInfo(index: $0["index"] as! Int, name: $0["name"] as! String, type: $0["type"] as! String)
    }
    if let p = c["pixelSize"] as? [Double] { e.metadata.pixelSizeMeters = (p[0], p[1]) }
    e.metadata.pixelUnit = c["pixelUnit"] as? String
    e.metadata.pixelUnitY = c["pixelUnitY"] as? String
    if let o = c["offset"] as? [Double] { e.metadata.offset = (o[0], o[1]) }
    e.metadata.accelerationVoltageVolts = c["voltage"] as? Double
    return e
}

@main struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
        var out: [String: Any] = [:]
        for c in cases {
            let name = c["name"] as! String
            switch args[1] {
            case "dm":
                out[name] = dump(AcquisitionMetadata.dm(numbers: c["numbers"] as! [String: Double], strings: c["strings"] as! [String: String]))
            case "mrc":
                let data = try Data(contentsOf: URL(fileURLWithPath: c["path"] as! String))
                do { out[name] = dump(try AcquisitionMetadata.mrc(data: data)) } catch { out[name] = ["error": "\(error)"] }
            case "tiff":
                let data = try Data(contentsOf: URL(fileURLWithPath: c["path"] as! String))
                do { out[name] = dump(try AcquisitionMetadata.tiff(data: data)) } catch { out[name] = ["error": "\(error)"] }
            case "tiffimage":
                let data = try Data(contentsOf: URL(fileURLWithPath: c["path"] as! String))
                do { out[name] = dumpImage(try TIFFImageReader.read(data: data, fileName: "x.tif")) } catch { out[name] = ["error": "\(error)"] }
            case "tiffimagebits":
                let data = try Data(contentsOf: URL(fileURLWithPath: c["path"] as! String))
                do { out[name] = dumpImageBits(try TIFFImageReader.read(data: data, fileName: "x.tif")) } catch { out[name] = ["error": "\(error)"] }
            case "mrcimage":
                let data = try Data(contentsOf: URL(fileURLWithPath: c["path"] as! String))
                do { out[name] = dumpImage(try MRCImageReader.read(data: data, fileName: "x.mrc")) } catch { out[name] = ["error": "\(error)"] }
            case "veloxobjects":
                let entries = (c["entries"] as! [[String: Any]]).map(entry)
                let chosen = VeloxImageReader.choose(entries)
                out[name] = ["chosen": chosen?.id ?? NSNull(),
                             "candidates": entries.filter(VeloxImageReader.isCandidate).map(\.id),
                             "axes": Dictionary(uniqueKeysWithValues: entries.map { e in
                                 let image = VeloxImageReader.image(e, pixels: [Float](repeating: 0, count: e.width * e.height), frame: 0, fileName: "x.emd")
                                 return (e.id, ["x": axis(image.x), "y": axis(image.y), "voltage": image.voltage ?? NSNull(), "notes": image.notes] as [String: Any])
                             })] as [String: Any]
            case "velox":
                var e = entry(c)
                e.metadata.accelerationVoltageVolts = c["accelerationVoltageVolts"] as? Double
                e.metadata.binaryResultDetector = c["binaryResultDetector"] as? String
                e.metadata.instrumentModel = c["instrumentModel"] as? String
                e.metadata.acquisitionStartUnixTime = c["acquisitionStartUnixTime"] as? Double
                e.metadata.dwellTimeSeconds = c["dwellTimeSeconds"] as? Double
                let entry = e
                out[name] = dump(AcquisitionMetadata.velox(entry, timeZone: TimeZone(identifier: "UTC")!))
            default: fatalError("kind")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(data)
    }
}
