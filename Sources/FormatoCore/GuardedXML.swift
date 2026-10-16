//
//  GuardedXML.swift
//  Role: the one way FormatoKit parses an XML document that a file carries (the Velox XML of a TIFF's tag 34683), used by
//        both readers of that tag (the TIFF calibration and the TIFF acquisition
//        values) so the two cannot drift. A document that breaks a bound below is REFUSED: the caller reads it as it
//        reads a file that holds no such tag (uncalibrated; nothing recorded), never as a crash and never as a value.
//
//  WHY. A tag's text is the file's, not ours. Measured 2026-10-12 on the unguarded `XMLDocument(xmlString:)` that both
//  readers used, through the TIFF acquisition-metadata and calibration readers:
//    - nesting: 50,000 levels (a 350 KB tag) end the process on the main thread (signal 11), 5,000 (35 KB) on a
//      background thread (signal 10); 20,000 on the main thread and 2,000 on a background thread still read;
//    - entities: a 747-byte tag whose DOCTYPE declares ten levels of ten references took 2.35 s and 9.4 GB, and the
//      expanded text (600 MB per element) lands in the values the reader shows;
//    - length: nothing bounds a value, so an 8 MB `<Detector>` is shown whole.
//  A textual scan for `<!DOCTYPE` / `<!ENTITY` is no defence: a prolog that declares `encoding="UTF-7"` hides both
//  strings and the entities still expand (measured: a 30 MB value from a tag holding neither literal).
//
//  WHAT. A first pass reads the document with Foundation's SAX parser, which decodes exactly as the tree parser does
//  (so no encoding trick can hide anything from it) and builds no tree: external entities are not resolved, and the
//  pass stops at the first of
//    - a tag over 4 MiB (`maxBytes`, refused before it is parsed);
//    - an element nested deeper than 64 (`maxDepth`);
//    - more than 1 MiB of text delivered (`maxCharacters`), CDATA included;
//    - any internal or unparsed entity declaration (a parameter entity's included): the kinds that expand. The
//      predefined entities (&amp; &lt; &gt; &quot; &apos;) and numeric references need none and still read;
//    - a document that is not well formed.
//  Only a document that passes is built as an `XMLDocument`, with `.nodeLoadExternalEntitiesNever` (without it a DOCTYPE
//  that names a local file puts that file's text into a value — measured — and merely building the tree opens the
//  file), and is then refused if its DTD declares any entity. That second look is needed for the EXTERNAL kind:
//  Foundation's SAX parser reports no external entity declaration while external entities are unresolved (measured
//  2026-10-12, macOS 27 SDK: `<!ENTITY s SYSTEM "file:///…">` and its PUBLIC form raise no callback, and a reference
//  to either reads as empty), but the tree lists them. The pass keeps `shouldResolveExternalEntities = false`: turning
//  it on would report the declaration and also load what it names.
//  A string value a reader would show is read only when it is at most 256 characters (`maxValueCharacters`, `bounded`).
//
//  THE NUMBERS. The six Ceta TIFFs the owner supplied (Talos F200X, 2026-06-05) hold tags of about 14 KB, nesting 6
//  deep, no text longer than 36 characters, an `encoding="utf-8"` prolog and no DOCTYPE: each bound is far above what
//  a Velox document has been seen to need, and below what takes a crash or a gigabyte. They are bounds on what the
//  parsers survive, not scientific thresholds: nothing the files record is near one. Not bounded: the NUMBER of
//  elements, which the size bound alone limits — a 4 MiB tag of 1.05 million empty elements was read in 2.4 s and 0.46 GB
//  (measured 2026-10-12, `-O`), slow and large but proportional to the tag, and no crash.
//

import Foundation

public nonisolated enum GuardedXML {
    /// A tag longer than this (UTF-8 bytes) is refused before it is parsed.
    public static let maxBytes = 4 * 1024 * 1024
    /// An element nested deeper than this is refused. The owner's Ceta tags are 6 deep.
    public static let maxDepth = 64
    /// More text than this (UTF-16 units of character data and CDATA, all elements together) is refused.
    public static let maxCharacters = 1024 * 1024
    /// A string value longer than this reads as absent (`bounded`).
    public static let maxValueCharacters = 256

    /// Which bound a refused document broke.
    public enum Refusal: Equatable, Sendable {
        case size, depth, characters, entity, malformed
    }

    /// The first bound the SAX pass finds `xml` breaking, or nil when the document may be built. Builds no tree, so it
    /// cannot see an external entity declaration (`document` does).
    public static func refusal(_ xml: String) -> Refusal? {
        guard xml.utf8.count <= maxBytes else { return .size }
        let watch = Watch()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = watch
        let parsed = parser.parse()
        withExtendedLifetime(watch) {}
        if let reason = watch.refusal { return reason }
        return parsed ? nil : .malformed
    }

    /// The document, or nil when it breaks a bound (`refusal`), declares an entity of any kind, or cannot be parsed.
    /// External entities are never loaded.
    public static func document(_ xml: String) -> XMLDocument? {
        guard refusal(xml) == nil,
              let document = try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]),
              document.dtd?.children?.contains(where: { $0.kind == .entityDeclaration }) != true else { return nil }
        return document
    }

    /// `value` when it is at most `maxValueCharacters` long, else nil: a string a reader would show is a short name,
    /// a mode or a stamp, never a document.
    public static func bounded(_ value: String?) -> String? {
        guard let value, value.count <= maxValueCharacters else { return nil }
        return value
    }

    /// Counts what the parser delivers and stops it at the first bound.
    private final class Watch: NSObject, XMLParserDelegate {
        var refusal: Refusal?
        private var depth = 0
        private var characters = 0

        private func refuse(_ reason: Refusal, _ parser: XMLParser) {
            if refusal == nil { refusal = reason }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            if depth > GuardedXML.maxDepth { refuse(.depth, parser) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            depth -= 1
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            characters += string.utf16.count
            if characters > GuardedXML.maxCharacters { refuse(.characters, parser) }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            characters += CDATABlock.count
            if characters > GuardedXML.maxCharacters { refuse(.characters, parser) }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            refuse(.entity, parser)
        }

        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
                    systemID: String?, notationName: String?) {
            refuse(.entity, parser)
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            if refusal == nil { refusal = .malformed }
        }
    }
}
