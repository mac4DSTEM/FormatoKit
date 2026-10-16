//
//  HDF5RootAttributesTests.swift
//  The root-attribute file layer (write, read, publish) by round trip, against h5py (tools/hdf5-write/generate.py: files h5py
//  wrote, and how h5py reads the golden file this writer produced), and the publish rules.
//

import CryptoKit
import Foundation
import Testing
import FormatoHDF5

@Suite(.serialized) struct HDF5RootAttributesTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/root-attributes")
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
    static let golden: [(name: String, value: String)] = [("identity", "1"), ("text", "Å 日本 😀 text"), ("empty", ""), ("long", String(repeating: "x", count: 30000))]

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Round trip and the golden file

    @Test func testWriteThenReadRoundTrips() throws {
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.h5")
        try HDF5RootAttributes.write(Self.golden, to: file)
        let got = try HDF5RootAttributes.read(Self.golden.map(\.name) + ["absent"], from: file)
        #expect(got["identity"] == "1" && got["text"] == "Å 日本 😀 text" && got["long"]?.utf8.count == 30000)
        #expect(got["empty"] == "", "an empty text is stored as one NUL and reads back empty")
        #expect(got["absent"] == nil)
    }

    @Test func testFreshWriteHasTheGoldenFilesLayout() throws {
        let golden = Self.fixture("kit-written.h5")
        if ProcessInfo.processInfo.environment["FORMATO_WRITE_GOLDEN"] != nil {
            try? FileManager.default.removeItem(at: golden)
            try HDF5RootAttributes.write(Self.golden, to: golden)
        }
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fresh.h5")
        try HDF5RootAttributes.write(Self.golden, to: file)
        // The bytes differ only where HDF5 stamps the file (checksummed headers carry times); the layout does not.
        let fresh = try Data(contentsOf: file), pinned = try Data(contentsOf: golden)
        #expect(fresh.count == pinned.count)
        #expect(fresh.prefix(8) == pinned.prefix(8), "the HDF5 signature")
        #expect(fresh[8] == pinned[8], "the superblock version")
        let names = Self.golden.map(\.name)
        #expect(try HDF5RootAttributes.read(names, from: file) == HDF5RootAttributes.read(names, from: golden))
    }

    @Test func testH5pyReadsTheGoldenFileAsTheWriterIntends() throws {
        let pins = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture("kit-written.h5py.json"))) as? [String: Any])
        let attributes = try #require(pins["attributes"] as? [String: [String: Any]])
        #expect(attributes.count == 4 && pins["groups"] as? Int == 0)
        for (name, value) in Self.golden {
            let a = try #require(attributes[name], "\(name)")
            let stored = value.isEmpty ? Data([0]) : Data(value.utf8)
            // Fixed-length, exactly as long as the text, UTF-8 (cset 1), null padded (strpad 1), scalar.
            if let hex = a["bytes_hex"] as? String { #expect(hex == stored.map { String(format: "%02x", $0) }.joined(), "\(name)") }
            #expect(a["sha256"] as? String == SHA256.hash(data: stored).map { String(format: "%02x", $0) }.joined(), "\(name)")
            #expect(a["size"] as? Int == stored.count && a["cset"] as? Int == 1 && a["strpad"] as? Int == 1 && a["rank"] as? Int == 0, "\(name)")
            #expect(a["class"] as? String == "string")
        }
        // Library-version bounds (V18, LATEST): a newer superblock than the default writes.
        #expect((pins["superblock_version"] as? Int ?? 0) >= 2)
    }

    @Test func testTheKitReadsWhatH5pyWrote() throws {
        let got = try HDF5RootAttributes.read(["identity", "text", "empty", "long", "ascii"], from: Self.fixture("h5py-written.h5"))
        #expect(got["identity"] == "1" && got["text"] == "Å 日本 😀 text" && got["empty"] == "" && got["ascii"] == "plain ascii")
        #expect(got["long"]?.utf8.count == 30000)
    }

    // MARK: Refusals

    @Test func testRefusalsByName() throws {
        #expect(throws: HDF5FileError.variableLengthString("text")) { try HDF5RootAttributes.read(["text"], from: Self.fixture("variable-length.h5")) }
        #expect(throws: HDF5FileError.malformedAttribute("text")) { try HDF5RootAttributes.read(["text"], from: Self.fixture("array-attribute.h5")) }
        #expect(throws: HDF5FileError.malformedAttribute("text")) { try HDF5RootAttributes.read(["text"], from: Self.fixture("not-a-string.h5")) }
        #expect(throws: HDF5FileError.malformedAttribute("text")) { try HDF5RootAttributes.read(["text"], from: Self.fixture("embedded-nul.h5")) }
        #expect(throws: HDF5FileError.invalidUTF8("text")) { try HDF5RootAttributes.read(["text"], from: Self.fixture("invalid-utf8.h5")) }
        #expect(throws: HDF5FileError.stringTooLong(attribute: "long", bytes: 30000)) {
            try HDF5RootAttributes.read(["long"], from: Self.fixture("h5py-written.h5"), maximumStringBytes: 1000)
        }
        #expect(throws: HDF5FileError.denseAttributeStorage) { try HDF5RootAttributes.read(["a00"], from: Self.fixture("dense.h5")) }
        #expect(throws: HDF5FileError.self) { try HDF5RootAttributes.read(["x"], from: Self.fixture("not-hdf5.h5")) }
        #expect(throws: HDF5FileError.self) { try HDF5RootAttributes.read(["x"], from: Self.fixture("does-not-exist.h5")) }
        #expect(throws: HDF5FileError.cannotOpen("not a file URL")) { try HDF5RootAttributes.read(["x"], from: URL(string: "https://example.com/a.h5")!) }
    }

    @Test func testAPermissionDeniedFileIsToldFromANonHDF5File() throws {
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("denied.h5")
        try HDF5RootAttributes.write(Self.golden, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        guard getuid() != 0 else { return }
        do { _ = try HDF5RootAttributes.read(["identity"], from: file); Issue.record("expected notPermitted") }
        catch let error as HDF5FileError { if case .notPermitted = error {} else { Issue.record("\(error)") } }
    }

    @Test func testAnEmbeddedNULIsRefusedBeforeAnyWrite() throws {
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nul.h5")
        #expect(throws: HDF5FileError.embeddedNUL("t")) { try HDF5RootAttributes.write([("t", "a\0b")], to: file) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Publishing

    @Test func testPublishNewReplaceAndTheChecksOnTheCheckedFile() throws {
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.h5")
        let one = dir.appendingPathComponent("one.tmp"), two = dir.appendingPathComponent("two.tmp"), three = dir.appendingPathComponent("three.tmp")
        for (file, id) in [(one, "1"), (two, "2"), (three, "3")] { try HDF5RootAttributes.write([("identity", id)], to: file) }
        // Nothing there: an exclusive rename.
        try HDF5RootAttributes.publish(one, onto: target, replacing: nil)
        #expect(try HDF5RootAttributes.read(["identity"], from: target)["identity"] == "1")
        // Something appeared after nothing was checked: refused, the file left as it is.
        #expect(throws: HDF5FileError.self) { try HDF5RootAttributes.publish(two, onto: target, replacing: nil) }
        #expect(try HDF5RootAttributes.read(["identity"], from: target)["identity"] == "1")
        // The same, on a volume without RENAME_EXCL.
        #expect(throws: HDF5FileError.self) { try HDF5RootAttributes.publish(two, onto: target, replacing: nil, exclusiveRenameUnavailable: true) }
        // Over the file that was checked.
        let checked = try #require(HDF5FileIdentity(ofItemAt: target.path))
        try HDF5RootAttributes.publish(two, onto: target, replacing: checked)
        #expect(try HDF5RootAttributes.read(["identity"], from: target)["identity"] == "2")
        // Not over a file that is no longer the one that was checked.
        #expect(throws: HDF5FileError.self) { try HDF5RootAttributes.publish(three, onto: target, replacing: checked) }
        #expect(try HDF5RootAttributes.read(["identity"], from: target)["identity"] == "2")
        #expect(HDF5FileIdentity(ofItemAt: dir.appendingPathComponent("missing").path) == nil)
    }

    @Test func testTheScratchURLIsNotASiblingAndItsNameIsShort() throws {
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent(String(repeating: "n", count: 255))
        let (url, scratchDirectory) = HDF5RootAttributes.temporaryURL(for: destination)
        defer { if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) } }
        #expect(url.lastPathComponent.utf16.count < 100 && url.lastPathComponent.hasPrefix(".formato-"))
        if let scratchDirectory {
            #expect(url.deletingLastPathComponent().standardizedFileURL == scratchDirectory.standardizedFileURL)
            #expect(scratchDirectory.standardizedFileURL != dir.standardizedFileURL)
        }
        // A temporary built there publishes onto the destination (atomic rename on the destination's volume).
        try HDF5RootAttributes.write([("identity", "1")], to: url)
        try HDF5RootAttributes.publish(url, onto: destination, replacing: nil)
        #expect(try HDF5RootAttributes.read(["identity"], from: destination)["identity"] == "1")
    }
}
