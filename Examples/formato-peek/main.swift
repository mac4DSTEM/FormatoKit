// swift run formato-peek <file> [maxPixels]: the header facts and the decimated frame Quick Look would draw (public API only).
import Foundation
import FormatoPeek

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("usage: formato-peek <file> [maxPixels]"); exit(2) }
let url = URL(fileURLWithPath: arguments[1])
let maxPixels = arguments.count > 2 ? Int(arguments[2]) ?? 512 : 512
do {
    let summary = try Peek.summary(url: url)
    print(summary)
    let frame = try Peek.thumbnailFrame(url: url, maxPixels: maxPixels)
    print("frame \(frame.width) x \(frame.height) (source \(frame.sourceWidth) x \(frame.sourceHeight), stride \(frame.stride), \(frame.kind), from \(frame.source)) range \(frame.pixels.min() ?? 0) ... \(frame.pixels.max() ?? 0)")
} catch {
    print("error: \(error.localizedDescription)"); exit(1)
}
