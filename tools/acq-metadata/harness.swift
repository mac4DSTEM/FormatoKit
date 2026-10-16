// The consumer's acquisition-metadata readers, compiled unchanged (macTEM cb6e164, Sources/TEMCore/Data/AcquisitionMetadata*.swift)
// with stand-ins for what they import, and run on the generator's cases. Prints one JSON object: case name -> fields.
import Foundation

// Stand-ins for the consumer's other types the readers name.
enum MRCImageReader { enum Refusal: Error { case notMRC(String), byteOrder(stamp: [UInt8]), truncated } }
enum TIFFImageReader { enum Refusal: Error { case notTIFF, sampleFormat(String), truncated } }
enum DM4Experiment {
    static func tagTree(data: Data) throws -> (numbers: [String: Double], strings: [String: String]) { throw TIFFImageReader.Refusal.truncated }
}
package struct VeloxMetadata {
    var accelerationVoltageVolts: Double?
    var binaryResultDetector: String?
    var instrumentModel: String?
    var acquisitionStartUnixTime: Double?
    var dwellTimeSeconds: Double?
}
package struct VeloxImageInfo { var metadata: VeloxMetadata; var detectorTypeValue: String? }
enum VeloxImageReader { package static func detectorType(of entry: VeloxImageInfo) -> String? { entry.detectorTypeValue } }

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
            case "velox":
                let m = VeloxMetadata(accelerationVoltageVolts: c["accelerationVoltageVolts"] as? Double,
                                      binaryResultDetector: c["binaryResultDetector"] as? String,
                                      instrumentModel: c["instrumentModel"] as? String,
                                      acquisitionStartUnixTime: c["acquisitionStartUnixTime"] as? Double,
                                      dwellTimeSeconds: c["dwellTimeSeconds"] as? Double)
                let entry = VeloxImageInfo(metadata: m, detectorTypeValue: c["detectorType"] as? String)
                out[name] = dump(AcquisitionMetadata.velox(entry, timeZone: TimeZone(identifier: "UTC")!))
            default: fatalError("kind")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(data)
    }
}
