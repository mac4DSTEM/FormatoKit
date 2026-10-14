// SpectroKit S1 test partition (ADR 064 section 3.3): the methods of DM4ExperimentTests that move with the EDX core;
// the rest stay in DM4ExperimentTests.swift. Helpers are duplicated, not shared, across the split.
import XCTest
import FormatoDM

/// v5.0 WP1 lane B: `DM4Experiment` lists every image object of a GMS `.dm4`
/// ("one experiment") and reads a 2D one back. The files are synthetic, built
/// tag by tag the way `FinalPolishDTests` builds its cube, but with the tag
/// layout of the owner's `134_STEM SI.dm4` / `036_STEM SI.dm4` (measured
/// 2026-10-05): unnamed `ImageList` entries, `Experiment keywords.{1,2}`, the
/// rect and survey ID under `SI.Acquisition.Survey Image` on the SI objects,
/// a root `Thumbnails` list. Test constants are deliberately asymmetric (a
/// rect of 14,222,515,569; x and y axes that differ) so a swap cannot hide.
final class DM4ExperimentSpectro: XCTestCase {

    // MARK: Synthetic DM4 writer

    private indirect enum Node {
        case int(String, Int32)
        case float(String, Float)
        case text(String, String)              // ushort array, as GMS writes strings
        case string18(String, [UInt8])         // type-18 string: info [18, length], then the bytes
        case structTag(String, [Int32])        // struct of int32 fields
        case bigArray(String, count: Int)      // uint8 array, over the 4 KiB keep limit
        case ints(String, [Int32])             // int32 array
        case uints(String, [UInt32])           // uint32 array
        case group(String, [Node])             // "" label = unnamed (one-based position)
        case blob(String, elementType: Int, bytes: [UInt8], count: Int)
        case rawInfo(String, [UInt64])         // a data tag with a hand-written info array and no payload
    }

    private static func u16be(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func u64be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) } }
    private static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> UInt64(8 * $0)) & 0xFF) } }

    private static func head(_ tag: UInt8, _ label: String) -> [UInt8] {
        [tag] + u16be(label.utf8.count) + Array(label.utf8) + u64be(0)
    }
    private static let delim: [UInt8] = [37, 37, 37, 37]

    private static func encode(_ node: Node) -> [UInt8] {
        switch node {
        case .int(let l, let v):
            return head(21, l) + delim + u64be(1) + u64be(3) + le(UInt64(UInt32(bitPattern: v)), 4)
        case .float(let l, let v):
            return head(21, l) + delim + u64be(1) + u64be(6) + le(UInt64(v.bitPattern), 4)
        case .text(let l, let s):
            let units = Array(s.utf16)
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(4) + u64be(UInt64(units.count))
                + units.flatMap { le(UInt64($0), 2) }
        case .string18(let l, let bytes):
            return head(21, l) + delim + u64be(2) + u64be(18) + u64be(UInt64(bytes.count)) + bytes
        case .structTag(let l, let fields):
            let n = fields.count
            return head(21, l) + delim + u64be(UInt64(3 + 2 * n)) + u64be(15) + u64be(0) + u64be(UInt64(n))
                + (0..<n).flatMap { _ in u64be(0) + u64be(3) }
                + fields.flatMap { le(UInt64(UInt32(bitPattern: $0)), 4) }
        case .bigArray(let l, let count):
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(8) + u64be(UInt64(count))
                + [UInt8](repeating: 7, count: count)
        case .ints(let l, let a):
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(3) + u64be(UInt64(a.count))
                + a.flatMap { le(UInt64(UInt32(bitPattern: $0)), 4) }
        case .uints(let l, let a):
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(5) + u64be(UInt64(a.count))
                + a.flatMap { le(UInt64($0), 4) }
        case .group(let l, let kids):
            return head(20, l) + [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        case .rawInfo(let l, let info):
            return head(21, l) + delim + u64be(UInt64(info.count)) + info.flatMap { u64be($0) }
        case .blob(let l, let t, let bytes, let count):
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(UInt64(t)) + u64be(UInt64(count)) + bytes
        }
    }

    private static func file(imageList: [Node], extraRoot: [Node] = []) -> Data {
        // Version 4, root length, byte order 1 (little-endian), then the root group body.
        let kids = [Node.group("ImageList", imageList)] + extraRoot
        let body: [UInt8] = [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        return Data([0, 0, 0, 4] + u64be(0) + [0, 0, 0, 1] + body)
    }

    // MARK: Fixture objects

    private typealias Axis = (origin: Float, scale: Float, units: String)
    private static let experiment = "Spectrum Imaging_10/5/2026_10:00:00 AM"
    private static let surveyID: [UInt32] = [11, 12, 13, 14]
    private static let rectValues: [Int32] = [14, 222, 515, 569]

    private static func calibrations(_ axes: [Axis]) -> Node {
        .group("Calibrations", [.group("Dimension", axes.map {
            .group("", [.float("Origin", $0.origin), .float("Scale", $0.scale), .text("Units", $0.units)])
        })])
    }

    private static func keywords(_ label: String?) -> [Node] {
        guard let label else { return [] }
        return [.group("Meta Data", [.group("Experiment keywords", [
            .group("", [.text("Experiment ID", experiment), .text("Label", "Spectrum Imaging")]),
            .group("", [.text("Label", label)]),
        ])])]
    }

    private static func surveyLink(rect: Bool = true, id: [UInt32] = surveyID) -> Node {
        .group("SI", [.group("Acquisition", [.group("Survey Image",
            [.uints("Unique Image ID", id)] + (rect ? [.ints("Spectrum Image Rect", rectValues)] : []))])])
    }

    private static func object(
        name: String, dataType: Int32, dims: [Int32], axes: [Axis],
        blobType: Int, blob: [UInt8], count: Int, tags: [Node], uniqueID: [Int32]? = nil
    ) -> Node {
        var kids: [Node] = [
            .text("Name", name),
            .group("ImageData", [
                .blob("Data", elementType: blobType, bytes: blob, count: count),
                .int("DataType", dataType),
                .group("Dimensions", dims.map { .int("", $0) }),
                calibrations(axes),
            ]),
            .group("ImageTags", tags),
        ]
        if let uniqueID { kids.append(.group("UniqueID", uniqueID.map { .int("", $0) })) }
        return .group("", kids)
    }

    private static func u16s(_ v: [UInt16]) -> [UInt8] { v.flatMap { le(UInt64($0), 2) } }
    private static func f32s(_ v: [Float]) -> [UInt8] { v.flatMap { le(UInt64($0.bitPattern), 4) } }
    private static func i16s(_ v: [Int16]) -> [UInt8] { v.flatMap { le(UInt64(UInt16(bitPattern: $0)), 2) } }

    private static let nm: Axis = (0, 0.5, "nm")
    private static let um: Axis = (0, 0.25, "µm")
    /// Different scale, units and origin from `nm`, so an x/y mix-up shows.
    private static let umY: Axis = (2, 0.75, "µm")
    private static let diffractionValues: [Int16] = (0..<24).map { Int16($0 * 7 - 50) }

    private static func thumbnail(dataType: Int32 = 23) -> Node {
        object(name: "Image Of 001_STEM SI", dataType: dataType, dims: [2, 1],
               axes: [(0, 1, ""), (0, 1, "")], blobType: 8,
               blob: [1, 2, 3, 4, 5, 6, 7, 8], count: 8, tags: [], uniqueID: [1, 1, 1, 1])
    }
    /// Carries, BEFORE the 4D object, a struct tag and an array over the keep limit.
    private static func survey(extraTags: [Node] = []) -> Node {
        object(name: "ADF Image (SI Survey)", dataType: 10, dims: [4, 3], axes: [nm, umY],
               blobType: 4, blob: u16s((0..<12).map { UInt16($0) }), count: 12,
               tags: keywords("Survey") + extraTags, uniqueID: surveyID.map { Int32($0) })
    }
    private static func scanSignal() -> Node {
        object(name: "HAADF Image", dataType: 2, dims: [2, 3], axes: [um, (0, 0.125, "nm")],
               blobType: 6, blob: f32s([0.5, 1.5, 2.5, 3.5, 4.5, 5.5]), count: 6,
               tags: keywords("Scan Signal") + [surveyLink()], uniqueID: [21, 22, 23, 24])
    }
    private static func diffraction() -> Node {
        object(name: "Diffraction SI", dataType: 1, dims: [2, 2, 2, 3],
               axes: [(0, 0.1, "1/nm"), (0, 0.1, "1/nm"), um, um],
               blobType: 2, blob: i16s(diffractionValues), count: 24,
               tags: keywords("Diffraction") + [surveyLink()], uniqueID: [31, 32, 33, 34])
    }
    private static func eds(extraTags: [Node] = []) -> Node {
        object(name: "EDS SI", dataType: 2, dims: [2, 3, 4], axes: [um, um, (20, 0.01, "keV")],
               blobType: 6, blob: f32s((0..<24).map { Float($0) }), count: 24,
               tags: keywords("EDS") + [surveyLink(), .group("EDS", [
                .group("Detector Info", [.float("Azimuthal angle", 45), .float("Elevation angle", 22.5)]),
                .float("Solid angle", 0.7), .float("Live time", 12.5), .float("Real time", 15),
               ])] + extraTags, uniqueID: [41, 42, 43, 44])
    }

    private static let thumbnails: Node = .group("Thumbnails", [.group("", [.int("ImageIndex", 0)])])
    private static let noise: [Node] = [.structTag("Struct", [3, -4, 5]), .bigArray("Big", count: 5000)]

    /// Struct and >4 KiB array BEFORE the 4D object. `withString` adds a type-18 string tag after it.
    private func fullFile(withString: Bool = false) -> Data {
        Self.file(imageList: [Self.thumbnail(), Self.survey(extraTags: Self.noise), Self.scanSignal(),
                              Self.diffraction(),
                              Self.eds(extraTags: withString ? [.string18("Note", Array("hello".utf8))] : [])],
                  extraRoot: [Self.thumbnails])
    }

    private func tempFile(_ data: Data) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dm4-experiment-\(UUID().uuidString).dm4")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func int16s(in data: Data, at offset: Int, count: Int) -> [Int16] {
        (0..<count).map { i in data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 2 * i, as: Int16.self) } }
    }

    // MARK: Listing

    func testMetaDataFormatAndSignalAreReportedVerbatim() throws {
        let with: [Node] = [.group("Meta Data", [.text("Format", "Spectrum image"), .text("Signal", "X-ray")])]
        let data = Self.file(imageList: [
            Self.object(name: "a", dataType: 2, dims: [2, 3], axes: [Self.um, Self.um],
                        blobType: 6, blob: Self.f32s([1, 2, 3, 4, 5, 6]), count: 6, tags: with),
            Self.object(name: "b", dataType: 2, dims: [2, 3], axes: [Self.um, Self.um],
                        blobType: 6, blob: Self.f32s([1, 2, 3, 4, 5, 6]), count: 6, tags: []),
        ])
        let o = try DM4Experiment.list(data: data)
        XCTAssertEqual(o[0].metaDataFormat, "Spectrum image")
        XCTAssertEqual(o[0].metaDataSignal, "X-ray")
        XCTAssertNil(o[1].metaDataFormat)
        XCTAssertNil(o[1].metaDataSignal)
    }

    /// Each object's own `ImageTags` reach it as two maps, the prefix removed, so a consumer reads one
    /// image's microscope and DataBar tags without a second parser. Eleven objects, so `ImageList.1.` sits
    /// beside `ImageList.10.` and `.11.`; the maps are compared whole, so a stray key of any kind shows.
    func testEachObjectExposesItsOwnImageTags() throws {
        let objects: [Node] = (1...11).map { n in
            var microscope: [Node] = [.float("Probe Current", Float(n) / 4)]
            var dataBar: [Node] = [.text("Device Name", "Camera \(n)")]
            if n == 1 {
                microscope.insert(.float("Voltage", 200_000), at: 0)
                dataBar.insert(.text("Acquisition Date", "10/12/2026 9:14:03 AM"), at: 0)
            }
            return Self.object(
                name: "o\(n)", dataType: 2, dims: [2, 3], axes: [Self.um, Self.um],
                blobType: 6, blob: Self.f32s([1, 2, 3, 4, 5, 6]), count: 6,
                tags: [.group("Microscope Info", microscope), .group("DataBar", dataBar)])
        }
        let o = try DM4Experiment.list(data: Self.file(imageList: objects))
        XCTAssertEqual(o.map(\.index), Array(1...11))
        XCTAssertEqual(o[0].voltage, 200_000)
        XCTAssertEqual(o[0].imageTagNumbers, ["Microscope Info.Voltage": 200_000, "Microscope Info.Probe Current": 0.25])
        XCTAssertEqual(o[0].imageTagStrings, ["DataBar.Acquisition Date": "10/12/2026 9:14:03 AM",
                                              "DataBar.Device Name": "Camera 1"])
        for object in o.dropFirst() {
            let n = object.index
            XCTAssertNil(object.voltage, "object \(n)")
            XCTAssertEqual(object.imageTagNumbers, ["Microscope Info.Probe Current": Double(Float(n) / 4)], "object \(n)")
            XCTAssertEqual(object.imageTagStrings, ["DataBar.Device Name": "Camera \(n)"], "object \(n)")
        }
    }

    /// Decoded read-only from the fixture's bytes: the four objects carry Format "Image", "Image",
    /// "Diffraction image", "Spectrum image"; only the last carries Signal "X-ray".
    func testTheRealEDSFixtureCarriesSpectrumImageAndXRay() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo-edx-tiny.dm4")
        let objects = try DM4Experiment.list(data: try Data(contentsOf: url))
        let si = try XCTUnwrap(objects.first { $0.role == .eds })
        XCTAssertEqual(si.metaDataFormat, "Spectrum image")
        XCTAssertEqual(si.metaDataSignal, "X-ray")
        XCTAssertEqual(objects.filter { $0.metaDataFormat == "Spectrum image" }.count, 1)
        XCTAssertEqual(objects.filter { $0.metaDataSignal != nil }.count, 1)
        // On the real file the tag map carries the same voltage the walk reads, on every object that has one.
        XCTAssertTrue(objects.contains { $0.voltage != nil })
        for object in objects where object.voltage != nil {
            XCTAssertEqual(object.imageTagNumbers["Microscope Info.Voltage"], object.voltage, "object \(object.index)")
        }
    }

    func testRolesAreListedFromTheExperimentLabels() throws {
        let objects = try DM4Experiment.list(data: fullFile())
        XCTAssertEqual(objects.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(objects.map(\.role), [.thumbnail, .survey, .scanSignal, .diffraction, .eds])
        XCTAssertEqual(objects.map(\.roleSource), [.thumbnailIndex, .label, .label, .label, .label])
        XCTAssertEqual(objects.map(\.name),
                       ["Image Of 001_STEM SI", "ADF Image (SI Survey)", "HAADF Image", "Diffraction SI", "EDS SI"])
        XCTAssertEqual(objects.map(\.dimensions), [[2, 1], [4, 3], [2, 3], [2, 2, 2, 3], [2, 3, 4]])
        XCTAssertEqual(objects.map(\.dataTypeName), ["rgba8", "uint16", "float32", "int16", "float32"])
        XCTAssertEqual(objects.map(\.label), [nil, "Survey", "Scan Signal", "Diffraction", "EDS"])
        // One run: every labelled object shares the Experiment ID; the thumbnail has none.
        XCTAssertNil(objects[0].experimentID)
        XCTAssertEqual(Set(objects.dropFirst().map(\.experimentID)), [Self.experiment])
        XCTAssertEqual(DM4Experiment.experimentIDs(in: objects), [Self.experiment])
        XCTAssertEqual(DM4Experiment.objects(inExperiment: Self.experiment, of: objects).map(\.index), [2, 3, 4, 5])
        // Calibration travels with the object (value at pixel i is (i - origin) * scale); x and y differ.
        XCTAssertEqual(objects[1].axes, [DM4Axis(origin: 0, scale: 0.5, units: "nm"),
                                         DM4Axis(origin: 2, scale: 0.75, units: "µm")])
        XCTAssertEqual(objects[4].axes[2]?.units, "keV")
        XCTAssertEqual(objects[4].axes[2]?.origin, 20)
        XCTAssertEqual(objects[4].axes[2]?.scale ?? 0, 0.01, accuracy: 1e-7)   // stored as Float32
    }

    func testTheSpectrumImageRectAndTheSurveyLinkAreParsed() throws {
        let objects = try DM4Experiment.list(data: fullFile())
        XCTAssertNil(objects[1].spectrumImageRect, "the survey itself carries no rect")
        let rect = try XCTUnwrap(objects[3].spectrumImageRect)
        XCTAssertEqual([rect.top, rect.left, rect.bottom, rect.right], [14, 222, 515, 569])
        XCTAssertEqual(rect.width, 347)
        XCTAssertEqual(rect.height, 501)
        XCTAssertEqual(objects[3].surveyImageID, Self.surveyID)
        XCTAssertEqual(objects[1].uniqueID, Self.surveyID)
        XCTAssertEqual(objects[3].uniqueID, [31, 32, 33, 34])
        for sibling in [objects[2], objects[3], objects[4]] {
            XCTAssertEqual(DM4Experiment.survey(for: sibling, in: objects)?.index, 2)
        }
        XCTAssertNil(DM4Experiment.survey(for: objects[1], in: objects))
    }

    func testTheSurveyLinkResolvesByIDNotByPosition() throws {
        // Two surveys in one file (two runs saved together): the link picks its own by ID.
        let other = Self.object(
            name: "ADF Image (SI Survey)", dataType: 10, dims: [4, 3], axes: [Self.nm, Self.nm],
            blobType: 4, blob: Self.u16s((0..<12).map { UInt16($0) }), count: 12,
            tags: Self.keywords("Survey"), uniqueID: [51, 52, 53, 54])
        let objects = try DM4Experiment.list(data: Self.file(imageList: [other, Self.survey(), Self.scanSignal()]))
        XCTAssertEqual(DM4Experiment.survey(for: objects[2], in: objects)?.index, 2)
        // An explicit ID that matches no survey resolves to nothing, with two candidates or with one.
        let stray = Self.object(
            name: "HAADF Image", dataType: 2, dims: [2, 3], axes: [Self.um, Self.um],
            blobType: 6, blob: Self.f32s([1, 2, 3, 4, 5, 6]), count: 6,
            tags: Self.keywords("Scan Signal") + [Self.surveyLink(id: [9, 9, 9, 9])])
        let two = try DM4Experiment.list(data: Self.file(imageList: [other, Self.survey(), stray]))
        XCTAssertNil(DM4Experiment.survey(for: two[2], in: two))
        let one = try DM4Experiment.list(data: Self.file(imageList: [Self.survey(), stray]))
        XCTAssertNil(DM4Experiment.survey(for: one[1], in: one), "a wrong ID is not rescued by the lone survey")
    }

    func testTheSurveysOwnIDFallsBackToItsImageTag() throws {
        // No ImageList.N.UniqueID group: the survey's `Survey Image.Unique Image ID` tag stands in.
        let survey = Self.object(
            name: "ADF Image (SI Survey)", dataType: 10, dims: [4, 3], axes: [Self.nm, Self.nm],
            blobType: 4, blob: Self.u16s((0..<12).map { UInt16($0) }), count: 12,
            tags: Self.keywords("Survey") + [.group("Survey Image", [.uints("Unique Image ID", Self.surveyID)])])
        let objects = try DM4Experiment.list(data: Self.file(imageList: [survey, Self.scanSignal()]))
        XCTAssertEqual(objects[0].uniqueID, Self.surveyID)
        XCTAssertEqual(DM4Experiment.survey(for: objects[1], in: objects)?.index, 1)
    }

    func testAFileWithoutASurveyStillListsCorrectly() throws {
        // A 4D run and a scan image, no survey, no thumbnail list; one object with no Experiment
        // keywords (role from its name, on an energy axis with origin 200 and scale 0.3), and a
        // label-less RGBA object (role from its data type).
        let noKeywords = Self.object(
            name: "EELS LL SI", dataType: 2, dims: [2, 3, 4], axes: [Self.um, Self.um, (200, 0.3, "eV")],
            blobType: 6, blob: Self.f32s((0..<24).map { Float($0) }), count: 24, tags: [])
        let data = Self.file(imageList: [
            Self.object(name: "HAADF Image", dataType: 2, dims: [2, 3], axes: [Self.um, Self.um],
                        blobType: 6, blob: Self.f32s([1, 2, 3, 4, 5, 6]), count: 6,
                        tags: Self.keywords("Scan Signal") + [Self.surveyLink(rect: false)]),
            Self.diffraction(), noKeywords, Self.thumbnail(),
        ])
        let objects = try DM4Experiment.list(data: data)
        XCTAssertEqual(objects.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(objects.map(\.role), [.scanSignal, .diffraction, .eels, .thumbnail])
        XCTAssertEqual(objects.map(\.roleSource), [.label, .label, .nameHeuristic, .rgbaFallback])
        XCTAssertNil(objects[2].label)
        XCTAssertNil(objects[2].experimentID)
        XCTAssertEqual(objects[2].axes[2]?.origin, 200)
        XCTAssertEqual(objects[2].axes[2]?.scale ?? 0, 0.3, accuracy: 1e-7)
        XCTAssertNil(objects[0].spectrumImageRect, "a link without a rect lists without one")
        XCTAssertEqual(objects[1].spectrumImageRect?.left, 222)
        XCTAssertNil(DM4Experiment.survey(for: objects[1], in: objects), "no survey in the file")
        XCTAssertEqual(try DM4Experiment.readImage(data: data, index: 1).pixels, [1, 2, 3, 4, 5, 6])
    }

    func testTheLabelDecidesNotTheNameAndAnUnknownLabelFallsToTheName() throws {
        // GMS object names are free text: a name that says "Survey" on a Scan Signal must not win.
        // An unrecognised label is no label: the name decides, and the object says so.
        func one(_ name: String, _ label: String) -> DM4ImageObject {
            try! DM4Experiment.list(data: Self.file(imageList: [
                Self.object(name: name, dataType: 2, dims: [2, 3], axes: [Self.um, Self.um],
                            blobType: 6, blob: Self.f32s([1, 2, 3, 4, 5, 6]), count: 6,
                            tags: Self.keywords(label))]))[0]
        }
        let decided = one("Renamed Survey Copy", "Scan Signal")
        XCTAssertEqual(decided.role, .scanSignal)
        XCTAssertEqual(decided.roleSource, .label)
        let guessed = one("Renamed Survey Copy", "Something New")
        XCTAssertEqual(guessed.role, .survey)
        XCTAssertEqual(guessed.roleSource, .nameHeuristic)
        XCTAssertNil(guessed.label, "an unrecognised label is not reported as the label")
    }

    func testKeywordPositionsAreNotRelied() throws {
        // The known Label sits in keyword group 2 (group 1 holds an unknown one) and the ID in group 3: found by scanning, not by position.
        let tags: [Node] = [.group("Meta Data", [.group("Experiment keywords", [
            .group("", [.text("Label", "Spectrum Imaging")]),
            .group("", [.text("Label", "EELS")]),
            .group("", [.text("Experiment ID", "run-9")]),
        ])])]
        let data = Self.file(imageList: [Self.object(
            name: "x", dataType: 2, dims: [2, 3], axes: [Self.um, Self.um],
            blobType: 6, blob: Self.f32s([1, 2, 3, 4, 5, 6]), count: 6, tags: tags)])
        let o = try DM4Experiment.list(data: data)[0]
        XCTAssertEqual([o.role, o.label, o.experimentID] as [AnyHashable?], [DM4ImageRole.eels, "EELS", "run-9"])
    }

    func testTheRootThumbnailListDecidesBeforeTheDataType() throws {
        // Object 1 is listed as a thumbnail by the root list although it is uint16, not RGBA.
        let data = Self.file(imageList: [Self.thumbnail(dataType: 10), Self.survey()], extraRoot: [Self.thumbnails])
        let objects = try DM4Experiment.list(data: data)
        XCTAssertEqual(objects[0].role, .thumbnail)
        XCTAssertEqual(objects[0].roleSource, .thumbnailIndex)
        XCTAssertEqual(objects[1].role, .survey)
    }

    func testEDSDetectorTagsAreListed() throws {
        let objects = try DM4Experiment.list(data: fullFile())
        let eds = try XCTUnwrap(objects[4].eds)
        XCTAssertEqual(eds.azimuthDegrees, 45)
        XCTAssertEqual(eds.elevationDegrees, 22.5)
        XCTAssertEqual(eds.solidAngle ?? 0, 0.7, accuracy: 1e-6)
        XCTAssertEqual(eds.liveTime, 12.5)
        XCTAssertEqual(eds.realTime, 15)
        XCTAssertNil(objects[3].eds, "no EDS tags, no EDS record")
    }

    // MARK: Reading

    func testA2DSurveyReadsBackExactly() throws {
        let data = fullFile()
        let survey = try DM4Experiment.readImage(data: data, index: 2)
        XCTAssertEqual(survey.width, 4)
        XCTAssertEqual(survey.height, 3)
        XCTAssertEqual(survey.pixels, (0..<12).map(Float.init))          // x fastest, row-major
        XCTAssertEqual(survey.xAxis, DM4Axis(origin: 0, scale: 0.5, units: "nm"))
        XCTAssertEqual(survey.yAxis, DM4Axis(origin: 2, scale: 0.75, units: "µm"))
        let scan = try DM4Experiment.readImage(data: data, index: 3)     // float32 scan-grid image
        XCTAssertEqual([scan.width, scan.height], [2, 3])
        XCTAssertEqual(scan.pixels, [0.5, 1.5, 2.5, 3.5, 4.5, 5.5])
        XCTAssertEqual(scan.xAxis?.units, "µm")
        XCTAssertEqual(scan.yAxis?.units, "nm")
    }

    func testEveryPixelTypeReadsBackWithItsSign() throws {
        // (DM data type, tag element type, bytes per pixel, [(bit pattern, expected Float)]).
        func s<T: BinaryInteger>(_ v: T) -> UInt64 { UInt64(truncatingIfNeeded: v) }
        let cases: [(Int32, Int, Int, [(UInt64, Float)])] = [
            (1, 2, 2, [-32768, -1, 0, 1, 32767, -300].map { (s(Int16($0)), Float($0)) }),
            (2, 6, 4, [-1.5, 0.25, -1e20, 3, 7.125, -0.0].map { (UInt64(Float($0).bitPattern), Float($0)) }),
            (6, 8, 1, [0, 1, 127, 128, 255, 200].map { (UInt64($0), Float($0)) }),
            (7, 3, 4, [-2_147_483_648, -1, 0, 1, 2_147_483_647, -70_000].map { (s(Int32($0)), Float($0)) }),
            (9, 10, 1, [-128, -1, 0, 1, 127, -50].map { (s(Int8($0)), Float($0)) }),
            (10, 4, 2, [0, 1, 32768, 65535, 300, 40000].map { (UInt64($0), Float($0)) }),
            (11, 5, 4, [0, 1, 2_147_483_648, 4_000_000_000, 70_000, 5].map { (UInt64($0), Float($0)) }),
            (12, 7, 8, [-1.5e10, 0.1, -0.0, 3.0e-5, 123456.789, -7].map { (Double($0).bitPattern, Float($0)) }),
        ]
        for (dtype, tagType, size, values) in cases {
            let bytes = values.flatMap { Self.le($0.0, size) }
            let data = Self.file(imageList: [Self.object(
                name: "t", dataType: dtype, dims: [3, 2], axes: [Self.nm, Self.umY],
                blobType: tagType, blob: bytes, count: values.count, tags: [])])
            let image = try DM4Experiment.readImage(data: data, index: 1)
            XCTAssertEqual([image.width, image.height], [3, 2], "data type \(dtype)")
            XCTAssertEqual(image.pixels, values.map(\.1), "data type \(dtype)")
        }
    }

    func testOnlyA2DImageIsReadAndEachRefusalSaysWhy() throws {
        let data = fullFile()
        func message(_ index: Int) -> String {
            do { _ = try DM4Experiment.readImage(data: data, index: index); return "no error" }
            catch DM4Error.cannotOpen(let m) { return m }
            catch DM4Error.unsupportedDataType(let t) { return "unsupported \(t)" }
            catch { return "other \(error)" }
        }
        XCTAssertTrue(message(4).contains("only a 2D image"), message(4))      // 4D
        XCTAssertTrue(message(5).contains("only a 2D image"), message(5))      // 3D EDS SI
        XCTAssertEqual(message(1), "unsupported 23")                           // RGBA thumbnail
        XCTAssertTrue(message(9).contains("no image object 9"), message(9))
    }

    func testA3DObjectWhoseDataTagDeclaresNoBytesIsStillRefused() throws {
        // The declared-0-bytes tolerance (some writers omit the count) must not let a 3D stack
        // through as its first plane.
        let data = Self.file(imageList: [Self.object(
            name: "EDS SI", dataType: 2, dims: [2, 3, 4], axes: [Self.um, Self.um, Self.um],
            blobType: 6, blob: [], count: 0, tags: Self.keywords("EDS"))
        ] + [Self.survey()])
        XCTAssertThrowsError(try DM4Experiment.readImage(data: data, index: 1)) { error in
            guard case DM4Error.cannotOpen(let m) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("only a 2D image"), m)
        }
    }

    // MARK: Byte source, grammar and the old reader

    func testTheFileHandlePathListsAndReadsTheSameAsData() throws {
        let data = fullFile()
        let path = try tempFile(data)
        XCTAssertEqual(try DM4Experiment.list(path: path), try DM4Experiment.list(data: data))
        XCTAssertEqual(try DM4Experiment.readImage(path: path, index: 2),
                       try DM4Experiment.readImage(data: data, index: 2))
    }

    func testListingNeverReadsTheBlob() throws {
        // A 2 MiB blob between the tags: listing may fetch tag windows, never the blob.
        let big = Self.object(
            name: "Diffraction SI", dataType: 6, dims: [1024, 2048], axes: [Self.nm, Self.nm],
            blobType: 8, blob: [UInt8](repeating: 9, count: 2_097_152), count: 2_097_152,
            tags: Self.keywords("Diffraction"))
        let path = try tempFile(Self.file(imageList: [big, Self.survey()]))
        let fetched = try DM4Experiment.bytesFetchedToList(path: path)
        XCTAssertLessThan(fetched, 400_000, "listing fetched \(fetched) bytes of a 2 MiB-blob file")
        XCTAssertEqual(try DM4Experiment.list(path: path).map(\.role), [.diffraction, .survey])
    }

    func testAType18StringTagBeforeTheFourDObjectDoesNotDesync() throws {
        // [18, length] then the bytes, nothing else (rsciio _api.py:121-127, :301-330). A reader
        // that took a further u32 here would skip into the blob; the 4D object must still be
        // found at the right offset.
        let long = [UInt8](repeating: 65, count: 6000)         // longer than the kept 4 KiB
        let data = Self.file(imageList: [
            Self.thumbnail(),
            Self.survey(extraTags: [.string18("Note", Array("ABCDEFGH".utf8)), .string18("Long", long)]),
            Self.diffraction(),
        ])
        let objects = try DM4Experiment.list(data: data)
        XCTAssertEqual(objects.map(\.role), [.thumbnail, .survey, .diffraction])
        let diffraction = objects[2]
        XCTAssertEqual(int16s(in: data, at: diffraction.dataOffset, count: 24), Self.diffractionValues)
    }

    func testATruncatedFileThrowsAtEveryCut() throws {
        // Every cut, byte by byte: inside the header, tag headers, info arrays, strings and blobs.
        // (A file that lost its tail has lost required tags, so none of them may list.)
        let data = fullFile(withString: true)
        for cut in 0..<data.count {
            XCTAssertThrowsError(try DM4Experiment.list(data: data.prefix(cut)), "cut at \(cut)")
        }
    }

    func testAFileThatIsNotDM3OrDM4IsRefusedByName() throws {
        let hdf5 = Data([0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 64))
        XCTAssertThrowsError(try DM4Experiment.list(data: hdf5)) { error in
            guard case DM4Error.cannotOpen(let m) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("DM3 or DM4"), m)
            XCTAssertTrue(m.contains("DM5"), m)
        }
    }

    func testMalformedNumbersThrowInsteadOfTrapping() throws {
        func listing(_ nodes: [Node]) -> Result<[DM4ImageObject], Error> {
            Result { try DM4Experiment.list(data: Self.file(imageList: nodes)) }
        }
        func objectWith(_ extra: Node) -> Node {
            .group("", [.text("Name", "x"), .group("ImageData", [
                .blob("Data", elementType: 6, bytes: f(6), count: 6), extra]), .group("ImageTags", [])])
        }
        func f(_ n: Int) -> [UInt8] { Self.f32s((0..<n).map { Float($0) }) }
        // A NaN data type, a 1e30 dimension, a negative dimension: each a thrown error.
        XCTAssertThrowsError(try listing([objectWith(.float("DataType", .nan))]).get())
        XCTAssertThrowsError(try listing([.group("", [.text("Name", "x"), .group("ImageData", [
            .blob("Data", elementType: 6, bytes: f(6), count: 6), .int("DataType", 2),
            .group("Dimensions", [.float("", 1e30), .int("", 2)])])])]).get())
        XCTAssertThrowsError(try listing([.group("", [.text("Name", "x"), .group("ImageData", [
            .blob("Data", elementType: 6, bytes: f(6), count: 6), .int("DataType", 2),
            .group("Dimensions", [.int("", -3), .int("", 2)])])])]).get())
        // Info arrays whose lengths cannot be real: a 2^63 length, a struct count far past the
        // info array, and an array-of-struct whose length overflows when multiplied.
        XCTAssertThrowsError(try listing([.rawInfo("A", [20, 15, 0, 0, UInt64.max])]).get())
        XCTAssertThrowsError(try listing([.rawInfo("B", [15, 0, 1_000_000])]).get())
        XCTAssertThrowsError(try listing([.rawInfo("C", [20, 15, 0, 1, 0, 3, UInt64(Int.max)])]).get())
        XCTAssertThrowsError(try listing([.rawInfo("D", [18, UInt64.max])]).get())
    }
}
