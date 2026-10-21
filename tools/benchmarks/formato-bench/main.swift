// formato-bench: the kit's side of tools/benchmarks/bench.py. One case file in (JSON), one JSON line out: five timed reads of the
// whole data after one warm-up read, the data sum (to prove the same work as RosettaSciIO's read), the peak resident size.
// Not a product: built with `swift build -c release --product formato-bench`.
import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoHDF5
import FormatoMIB
import FormatoMRC
import FormatoMSA
import FormatoEMPAD
import FormatoTIFF

let args = CommandLine.arguments
guard args.count >= 2, let spec = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1])))) as? [String: Any],
      let kind = spec["kind"] as? String, let path = spec["path"] as? String else {
    FileHandle.standardError.write(Data("usage: formato-bench <case.json>\n".utf8)); exit(2)
}

/// Opens the file and returns all its data (what RosettaSciIO's `file_reader(lazy=False)` returns), the first signal.
func read() throws -> FormatoArray {
    switch kind {
    case "dm":
        let dm = try DMFile(path: path)
        return try dm.signal(index: dm.objects[0].index).load().data
    case "dm4d":
        return try DM4Datacube(path: path).signal.load().data
    case "velox-images":
        let images = try VeloxImageSignals(path: path)
        return try images.signal(images.images[0]).load().data
    case "velox-spectrum":
        return try VeloxSpectrumSignals(path: path).signals[0].data
    case "velox-si":
        return try VeloxSpectrumImageSignals(path: path).signals[0].data
    case "tiff":
        let tiff = try TIFFSignals(path: path)
        return try tiff.signal(series: 0).load().data
    case "mrc":
        return try MRCReader(path: path).signal.load().data
    case "mib":
        return try MIBReader(path: path).signal.load().data
    case "empad":
        return try EMPADReader(path: path).signal.load().data
    case "hdf5":
        return try HDF5Datacube(path: path, datasetPath: spec["dataset"] as! String).signal.load().data
    case "msa":
        return try MSAReader.read(path: path).signal.data
    default:
        throw FormatoReadError.unsupported("unknown case kind \(kind)")
    }
}

do {
    _ = try read()   // warm-up: library load, page cache
    var times: [Double] = []
    var last: FormatoArray?
    for _ in 0..<5 {
        let clock = ContinuousClock()
        var data: FormatoArray?
        let elapsed = try clock.measure { data = try read() }
        times.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        last = data
    }
    let array = last!
    var sum = 0.0
    for v in array.doubles() { sum += v }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let out: [String: Any] = ["times": times, "rss_mb": Double(usage.ru_maxrss) / 1e6, "sum": sum, "shape": array.shape]
    print(String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
}
