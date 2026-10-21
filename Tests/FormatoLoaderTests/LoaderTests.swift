import Testing
import Foundation
import FormatoCore
import Formato

private let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private func path(_ relative: String) -> String { tests.appendingPathComponent(relative).path }

@Test func sniffsEachFormatByExtensionAndBytes() {
    #expect(FormatoLoader.sniff(path: path("FormatoDMTests/Fixtures/eels-planted.dm4")) == .digitalMicrograph)
    #expect(FormatoLoader.sniff(path: path("FormatoTIFFTests/Fixtures/planted/fei-helios.tif")) == .tiff)
    #expect(FormatoLoader.sniff(path: path("FormatoEMDTests/Fixtures/velox-titles-v6-image.emd")) == .veloxEMD)
    #expect(FormatoLoader.sniff(path: path("FormatoEMDTests/Fixtures/spectra/sp-single.emd")) == .veloxEMD)
    #expect(FormatoLoader.sniff(path: path("FormatoMSATests/Fixtures/public/example1.msa")) == .msa)
    // The extension of one format on the bytes of another is unknown; a missing file is unknown.
    #expect(FormatoLoader.sniff(path: path("FormatoMSATests/Fixtures/public/example1.msa").replacingOccurrences(of: ".msa", with: ".dm4")) == .unknown)
    #expect(FormatoLoader.sniff(path: path("FormatoDMTests/Fixtures/eels-planted.truth.json")) == .unknown)
}

@Test func loadsSignalsAndNamesTheOthers() throws {
    // A DM file: every object, the refused ones as errors.
    let dm = try FormatoLoader.load(path: path("FormatoDMTests/Fixtures/eels-planted.dm4"))
    #expect(dm.count == 21)
    // A Velox file with single spectra: spectra first, then images, then spectrum images (RosettaSciIO's order).
    let spectra = try FormatoLoader.load(path: path("FormatoEMDTests/Fixtures/spectra/sp-stream.emd"))
    let titles = try spectra.map { try $0.get().title }
    #expect(titles.first == "SuperXG11" && spectra.count >= 1)
    let one = try FormatoLoader.load(path: path("FormatoEMDTests/Fixtures/spectra/sp-single.emd"))
    #expect(try one.count == 1 && one[0].get().signalType == "EDS_TEM" && one[0].get().array.shape == [12])
    // MSA arrives as an in-memory lazy signal.
    let msa = try FormatoLoader.load(path: path("FormatoMSATests/Fixtures/public/example1.msa"))
    #expect(try msa.count == 1 && msa[0].get().load().data.dataType == .float64)
    // 4D formats are named, not loaded; an unknown file is refused by name.
    #expect(throws: FormatoLoadError.self) { _ = try FormatoLoader.load(path: path("FormatoDMTests/Fixtures/eels-planted.truth.json")) }
}
