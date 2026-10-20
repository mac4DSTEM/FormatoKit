import Foundation
import DSTEMCore

// Offline oracle: runs mac4DSTEM's own EMD writers (the app's Core at HEAD c47a2b7a, kits at the app's pins) on fixed inputs.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func rm(_ u: URL) { try? FileManager.default.removeItem(at: u) }

func calibration(maps: Bool) -> PixelCalibration {
    var c = PixelCalibration()
    c.rSize = 0.5; c.rUnits = "nm"; c.qSize = 0.02; c.qUnits = "A^-1"; c.qrFlip = true
    c.qx0Mean = 12.25; c.qy0Mean = 13.5; c.ellipseA = 1.5; c.ellipseB = 1.25; c.ellipseTheta = 0.3
    c.qrRotationRad = 0.5; c.qrRotationConvention = "py4DSTEM"; c.probeSemiangle = 1.75
    if maps {
        let n = 12
        c.originMaps = PixelOriginMaps(shape: [3, 4],
            fittedQX: (0..<n).map { 12 + Double($0) * 0.125 }, fittedQY: (0..<n).map { 13 + Double($0) * 0.0625 },
            measuredQX: (0..<n).map { 12.5 + Double($0) * 0.25 }, measuredQY: (0..<n).map { 13.5 + Double($0) * 0.125 })
        c.qx0Mean = nil; c.qy0Mean = nil   // derived from the maps by the writer
    }
    return c
}

// 1. Calibrated 4D datacube.
do {
    let source = DemoFourDDataSource()
    let view = LoadView(fullExtentOf: DemoFourDDataSource.descriptor)
    let options = CalibratedDataCubeExportOptions(scanY: 0..<4, scanX: 0..<5, qBin: 2, tileRows: 2, scanStride: 1,
                                                  qCropY: 8..<24, qCropX: 8..<26)
    let url = out.appendingPathComponent("app-datacube.h5"); rm(url)
    let summary = try await BraggVectorEMDWriter.writeCalibratedDataCube(
        source: source, view: view, calibration: calibration(maps: false), acceleratingVoltageKV: 200,
        options: options, to: url, sourceFileName: "demo.h5")
    print("datacube", summary.shape)
}

// 2. Session sidecar: BraggVectors, calibration with origin maps, a scalar map and an RGBA map.
do {
    let url = out.appendingPathComponent("app-sidecar.h5"); rm(url)
    var peaks: [[BraggPeak]] = []
    for i in 0..<12 {
        peaks.append(i % 5 == 4 ? [] : (0..<(i % 3 + 1)).map { k in
            BraggPeak(x: Float(2 + i) + Float(k) * 0.5, y: Float(3 + k) - Float(i) * 0.25, intensity: Float(100 + i * 10 + k)) })
    }
    let vectors = BraggVectors(scanWidth: 4, scanHeight: 3, peaks: peaks, detectionProvenance: ["detector": "oracle", "sigma": "1.5"])
    let cal = calibration(maps: true)
    try BraggVectorEMDWriter.write(vectors: vectors, qWidth: 20, qHeight: 16, calibration: cal, to: url)
    let scalar = ScalarResultMap(width: 4, height: 3, pixels: (0..<12).map { Float($0) * 0.5 - 1 }, kind: "strain_exx",
        displayName: "Strain εxx", valueUnits: "%", pixelSizeRow: 0.5, pixelSizeColumn: 0.75, pixelUnits: "nm",
        provenance: ["method": "oracle", "bin": "2"])
    try BraggVectorEMDWriter.mergeResultMap(scalar, vectors: nil, qWidth: 20, qHeight: 16, calibration: cal, to: url)
    let rgba = RGBAResultMap(width: 4, height: 3, rgba: (0..<48).map { UInt8($0 * 5 % 256) }, kind: "orientation_map",
        displayName: "Orientation", valueUnits: "rgb", pixelSizeRow: nil, pixelSizeColumn: nil, pixelUnits: nil, provenance: [:])
    try BraggVectorEMDWriter.mergeRGBAResultMap(rgba, vectors: nil, qWidth: 20, qHeight: 16, calibration: cal, to: url)
    print("sidecar ok")
}

// 3. Scientific bundle (two scalar fields, calibration without a target).
do {
    let url = out.appendingPathComponent("app-bundle.h5"); rm(url)
    let a = ScalarResultMap(width: 4, height: 3, pixels: (0..<12).map { Float($0) * 0.25 }, kind: "strain_exx",
        displayName: "Strain εxx", valueUnits: "%", pixelSizeRow: 0.5, pixelSizeColumn: 0.5, pixelUnits: "nm", provenance: ["m": "x"])
    let b = ScalarResultMap(width: 4, height: 3, pixels: (0..<12).map { -Float($0) }, kind: "rotation",
        displayName: "Rotation", valueUnits: "deg", provenance: [:])
    try BraggVectorEMDWriter.writeScientificBundle(maps: [a, b], calibration: calibration(maps: true), to: url)
    print("bundle ok")
}
