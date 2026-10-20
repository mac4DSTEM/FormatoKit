//
//  TIFFAppImageTests.swift
//  TIFFAppImage against the consumer's reader (macTEM cb6e164 TIFFImageReader.swift, compiled unchanged by
//  tools/acq-metadata/generate.py) on TIFFs written byte by byte: pixels as Float bit patterns, axes as Double bit patterns,
//  notes, source string and refusal, all exact (D12: readers, I/O and metadata are exact). And against `TIFFSignals`, to show
//  the option differs from RosettaSciIO's reading only where its header documents.
//

import Foundation
import Testing
import FormatoCore
import FormatoTIFF

@Suite struct TIFFAppImageTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/app-image")
    static var pins: [[String: Any]] {
        let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("pins.json"))) as? [String: Any]
        return root?["cases"] as? [[String: Any]] ?? []
    }
    static func path(_ name: String) -> String { fixtures.appendingPathComponent(name + ".tif").path }
    static func pin(_ name: String) -> [String: Any] { (pins.first { $0["name"] as? String == name }?["app"] as? [String: Any]) ?? [:] }

    /// Cases where the kit differs from the consumer's reader on purpose (header comment of TIFFAppImage): a tag whose value
    /// lies outside the file is `truncated` here, absent in the consumer's lazy walker.
    static let documentedDifferences: [String: TIFFAppImage.Refusal] = ["tag-value-outside-file": .truncated]

    static func bits(_ axis: TIFFAppImage.Axis?) -> [String: String]? {
        axis.map { ["origin": String($0.origin.bitPattern, radix: 16), "scale": String($0.scale.bitPattern, radix: 16), "units": $0.units] }
    }

    /// The reading of `name`, or nil with the case named when it throws.
    static func image(_ name: String) -> TIFFAppImage.Image? {
        do { return try TIFFAppImage.read(path: path(name)) } catch { Issue.record("\(name): \(error)"); return nil }
    }

    @Test func testPinsAreComplete() throws {
        #expect(Self.pins.count == 149)
        for c in Self.pins {
            let name = c["name"] as! String
            #expect(FileManager.default.fileExists(atPath: Self.path(name)), "\(name)")
        }
    }

    @Test func testReadingEqualsTheConsumersReader() throws {
        var read = 0, refused = 0
        for c in Self.pins {
            let name = c["name"] as! String
            if Self.documentedDifferences[name] != nil { continue }
            let app = c["app"] as! [String: Any]
            if let expected = app["error"] as? String {
                refused += 1
                do {
                    _ = try TIFFAppImage.read(path: Self.path(name))
                    Issue.record("\(name): expected \(expected)")
                } catch { #expect("\(error)" == expected, "\(name): \(error)") }
                continue
            }
            read += 1
            guard let image = Self.image(name) else { continue }
            #expect(image.width == app["width"] as? Int && image.height == app["height"] as? Int, "\(name)")
            #expect(image.pixels.map { Int($0.bitPattern) } == app["pixels"] as? [Int], "\(name) pixels")
            #expect(image.notes == app["notes"] as? [String], "\(name) notes")
            #expect(image.source == app["source"] as? String, "\(name) source")
            #expect(image.fileName == name + ".tif", "\(name)")
            for (axis, key) in [(image.x, "x"), (image.y, "y")] {
                #expect(Self.bits(axis) == app[key] as? [String: String], "\(name) \(key)")
            }
        }
        #expect(read == 102 && refused == 46)
    }

    @Test func testDocumentedDifferenceFromTheConsumersWalker() throws {
        // The consumer reads an out-of-file tag value as absent (the image opens, DM tags without a scale); TIFFFile refuses it.
        #expect(Self.pin("tag-value-outside-file")["error"] == nil)
        #expect(throws: TIFFAppImage.Refusal.truncated) { try TIFFAppImage.read(path: Self.path("tag-value-outside-file")) }
    }

    @Test func testRefusalsAreTypedAndWorded() throws {
        let expected: [String: TIFFAppImage.Refusal] = [
            "not-tiff-letters": .notTIFF, "too-short": .notTIFF, "ifd-offset-outside": .truncated, "second-page": .multiPage,
            "imagej-stack-images": .multiPage, "compressed-lzw": .compressed(scheme: 5), "tiled": .tiled,
            "rgb-unequal-blue-row1-col2": .unequalChannels(row: 1, column: 2), "bigtiff-II": .sampleFormat("BigTIFF"),
            "white-is-zero": .sampleFormat("1 sample(s) per pixel, photometric 0, planar 1"), "huge-width-overflow": .truncated,
        ]
        for (name, refusal) in expected {
            #expect(throws: refusal) { try TIFFAppImage.read(path: Self.path(name)) }
            #expect(!refusal.reason.isEmpty && refusal.reason.hasSuffix("."), "\(name)")
        }
        #expect(TIFFAppImage.Refusal.compressed(scheme: 5).reason == "its pixels are compressed (scheme 5); only uncompressed TIFF is read.")
        #expect(TIFFAppImage.Note.render == "8-bit render, not counts")
        #expect(TIFFAppImage.Note.veloxUnvalidated == "scale unvalidated (one acquisition)")
        #expect(throws: FormatoReadError.self) { try TIFFAppImage.read(path: Self.path("no-such-file")) }
    }

    @Test func testUnequalChannelsCanBeAcceptedForTheNegativeControl() throws {
        let strict = try? TIFFAppImage.read(path: Self.path("rgb-unequal-red-first-pixel"))
        #expect(strict == nil)
        let loose = try TIFFAppImage.read(path: Self.path("rgb-unequal-red-first-pixel"), acceptUnequalChannels: true)
        #expect(loose.pixels.count == 6 && loose.pixels[0] == Float(3 ^ 0x10))
    }

    /// Every case both readers accept: the pixel values are the same numbers (as Float). `TIFFSignals` keeps the stored type;
    /// the option converts it to Float32, so equality here is the whole claim.
    @Test func testPixelsEqualTIFFSignalsWhereBothReaders() throws {
        var compared: [String] = [], signalsRefuses: [String] = []
        for c in Self.pins {
            let name = c["name"] as! String
            guard (c["app"] as! [String: Any])["error"] == nil, Self.documentedDifferences[name] == nil else { continue }
            guard let image = Self.image(name) else { continue }
            guard let signal = try? TIFFSignals(path: Self.path(name)).signal(series: 0).load() else { signalsRefuses.append(name); continue }
            let values = signal.data.doubles()
            let components = signal.data.dataType.components
            #expect(signal.data.shape == [image.height, image.width], "\(name) shape")
            for (i, p) in image.pixels.enumerated() {
                for k in 0..<components {
                    #expect(Float(values[i * components + k]).bitPattern == p.bitPattern, "\(name) pixel \(i) sample \(k)")
                }
            }
            compared.append(name)
        }
        // The cases TIFFSignals cannot read as a 2D series (stacks are refused here, so these are single images): a file with
        // no PhotometricInterpretation, or a vendor-branch / layout rule of its own.
        #expect(compared.count == 101, "\(compared.count) compared")
        // TIFFSignals refuses a page without PhotometricInterpretation (RosettaSciIO raises); the option reads it as grey.
        #expect(signalsRefuses == ["grey-no-photometric"], "\(signalsRefuses)")
    }

    static func signalAxes(_ name: String) throws -> (width: FormatoAxis, height: FormatoAxis) {
        let axes = try TIFFSignals(path: path(name)).signal(series: 0).axes
        return (try #require(axes.first { $0.name == "width" }), try #require(axes.first { $0.name == "height" }))
    }

    /// FEI SEM: the consumer puts PixelWidth on x; tifffile (RosettaSciIO 049e7d70) puts the width's scale on the height axis,
    /// so the two readings agree on square pixels and swap on non-square ones, under [Scan] and under the [IRBeam] fallback.
    @Test func testFEIPixelWidthIsXWhereTIFFSignalsSwapsIt() throws {
        let square = try TIFFAppImage.read(path: Self.path("fei-square")), signalSquare = try Self.signalAxes("fei-square")
        #expect(square.x?.scale == 1e-08 && square.y?.scale == 1e-08 && signalSquare.width.scale == 1e-08 && signalSquare.height.scale == 1e-08)
        for name in ["fei-non-square", "fei-non-square-MM-34680", "fei-irbeam-fallback"] {
            let image = try TIFFAppImage.read(path: Self.path(name)), axes = try Self.signalAxes(name)
            let x = try #require(image.x), y = try #require(image.y)
            #expect(x.scale != y.scale && x.units == "m" && y.units == "m", "\(name)")
            #expect(axes.width.scale == y.scale && axes.height.scale == x.scale, "\(name): TIFFSignals swaps the two scales")
        }
        let image = try TIFFAppImage.read(path: Self.path("fei-non-square"))
        #expect(image.x?.scale == 2.5e-09 && image.y?.scale == 5e-09)
    }

    /// The other documented differences from TIFFSignals, each shown on a file.
    @Test func testDocumentedDifferencesFromTIFFSignals() throws {
        // A DM scale of 0 (or below) is no axis here; TIFFSignals keeps it as written.
        for name in ["dm-scale-zero", "dm-scale-negative", "dm-scale-infinite"] {
            let image = try TIFFAppImage.read(path: Self.path(name))
            #expect(image.x == nil && image.y?.scale == 0.5, "\(name)")
        }
        #expect(try Self.signalAxes("dm-scale-zero").width.scale == 0)
        #expect(try Self.signalAxes("dm-scale-negative").width.scale == -0.5)
        // An axis without a unit is nil here; TIFFSignals gives the scale with an empty unit.
        #expect(try TIFFAppImage.read(path: Self.path("dm-no-units")).x == nil)
        #expect(try Self.signalAxes("dm-no-units").width.scale == 0.25)
        // A non-numeric FEI value leaves both axes uncalibrated, as in TIFFSignals.
        #expect(try TIFFAppImage.read(path: Self.path("fei-scan-nonnumeric")).x == nil)
        // Read by TIFFSignals, refused here by name: inverted greys, palettes, a second page, a stack.
        for name in ["white-is-zero", "palette", "second-page", "imagej-stack-images"] {
            #expect(throws: TIFFAppImage.Refusal.self, "\(name)") { try TIFFAppImage.read(path: Self.path(name)) }
            #expect((try? TIFFSignals(path: Self.path(name)).signal(series: 0)) != nil, "\(name)")
        }
        // ImageJ's "nm" is uncalibrated in both; "micron" is "µm" in both.
        #expect(try TIFFAppImage.read(path: Self.path("imagej-nm")).x == nil && Self.signalAxes("imagej-nm").width.units == "")
        #expect(try TIFFAppImage.read(path: Self.path("imagej-micron")).x?.units == "µm" && Self.signalAxes("imagej-micron").width.units == "µm")
    }
}
