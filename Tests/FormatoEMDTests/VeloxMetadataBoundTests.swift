import Testing
import Foundation
import FormatoCore
import FormatoEMD
import FormatoHDF5

extension VeloxEMDSerialized {
    /// A Velox file's metadata row count comes out of the file; a corrupt or hostile one must be refused before it is allocated.
    /// The 8.9 kB file (raw-deflate base64, like the other Velox fixtures) holds a Version dataset and one SpectrumStream whose
    /// `Metadata` is a chunked uint8 dataset of (2^30, 1) with no chunk written: unguarded, the reader would allocate 1 GiB and read
    /// fill values into it. Real files have 60000 rows (111 datasets measured, 2026-10-12).
    @Suite(.serialized) final class VeloxMetadataBoundTests {
        /// XCTest's `addTeardownBlock`, kept: blocks run in reverse order when the test's suite instance goes away.
        private var teardownBlocks: [() -> Void] = []
        private func addTeardownBlock(_ block: @escaping () -> Void) { teardownBlocks.append(block) }
        deinit { for block in teardownBlocks.reversed() { block() } }

        private static let hugeMetadataBase64 = "7Zm/TwIxFMfbHsQLiRE3RIJn48DgAKsTxkMZVIwY4uhFz2giQo7TkBgTRt0cHR0ZHR0dGf2PkNIWrpVfAQcS3md593rvXpu7b98lr695e385Eo8ghmmiEIqiIG1Bi6q+vH8hLBb2RdgmkeO4ey8mxldFfj3u7DSXY9FtDTlPOsStiYBFJJ/bPWH2XPhSTy2ixpVcr3ZbuUe24ztBXWannBejMM+BpW8qejc6K2HXaxh3lR3t3eNx4Y5lPiF82BQrN2Qibb8h9D7X36F4XLAxIr1V18Pq/v8QfjSm7lfLAA2ruhpcF/X3N64uWutQF0FHA/6vYqAZH/38FtOa2d/DB3uFQxwoSzgQx3ii1xWv7Ph0x6Il965Sp9sWfeRFl41lMvQ5mP9rBb4RAAAAAAAAAAAAAMwbw/qs6ZgaV6y6l773UC76nuuUZ++zjutzpTa4hT4X6JIh+88trb9VS3Mr9ZifcV7e7+4169H3kpp/0j7bojOsT/mW4P5ncrI60NiEOgB14O//6Sepxh25vnMlzgCD+zX7T3XgJqHm1XUMDKsD+nlqilsi3yT/RLj/iOIbnbqB0YhzVkM7ZyVGv4TwEiRSNebifei6qlqgkWn4BQ=="

        /// Mutation: the guard in `VeloxFile.readMetadataJSON` removed (in the copy) - the call allocates 1 GiB and no longer throws: red.
        @Test func testAnOversizedMetadataDatasetIsRefusedBeforeItIsAllocated() throws {
            let compressed = try #require(Data(base64Encoded: Self.hugeMetadataBase64))
            let raw = try (compressed as NSData).decompressed(using: .zlib) as Data
            let path = NSTemporaryDirectory() + "velox-huge-metadata-\(UUID().uuidString).emd"
            try raw.write(to: URL(fileURLWithPath: path))
            addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
            let error = #expect(throws: (any Error).self) { try VeloxEMDReader(path: path).readSpectrumImage() }
            if let error {
                if case VeloxEMDError.readFailed(let what) = error {
                    #expect(what.contains("1073741824"), Comment(rawValue: what))
                    #expect(what.contains("16777216"), Comment(rawValue: what))
                } else { Issue.record("wrong error: \(error)") }
            }
        }
    }
}
