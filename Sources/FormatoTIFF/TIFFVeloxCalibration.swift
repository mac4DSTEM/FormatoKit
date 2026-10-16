//
//  TIFFVeloxCalibration.swift
//  The pixel size of a Thermo/FEI Velox TIFF (Ceta and other TEM cameras): `BinaryResult/PixelSize` X and Y of the XML in
//  private tag 34683, each in the unit its `unit` attribute names, cross-checked against the private tags 65450 / 65451
//  (pixels per unit of tag 65452, 3 = centimetres). No RosettaSciIO plugin reads this convention (its tiff reader ignores
//  tag 34683), so the default `TIFFSignals` leaves such a file uncalibrated; the first consumer's reading is the named
//  option `TIFFReadOptions.veloxCalibration`, pinned to the consumer's source (macTEM cb6e164 TIFFImageReader.swift,
//  compiled unchanged by tools/acq-metadata/generate.py). The XML's Offset is not read and its ImageSize is not used.
//
//  Velox writes the pixel count per centimetre as a RATIONAL n/1 after a float32 rounding (the owner's 630 kx file:
//  224 125 360, a multiple of 16, where the XML implies 224 125 354.07): the tags agree with the XML within half a count
//  plus half a float32 step at that count. A disagreement leaves the image uncalibrated and says why.
//

import Foundation
import FormatoCore

public nonisolated enum TIFFVeloxCalibration: Sendable, Equatable {
    /// Scale and unit of the x (columns) and y (rows) axes, as the XML states them.
    case calibrated(xScale: Double, xUnit: String, yScale: Double, yUnit: String)
    /// The XML and the resolution tags name different sizes.
    case disagree

    /// The note of a calibrated reading: the scale comes from one convention seen on one acquisition.
    public static let unvalidatedNote = "scale unvalidated (one acquisition)"
    /// The note of `disagree`.
    public static let disagreeNote = "uncalibrated: the Velox XML and the resolution tags disagree"

    /// The calibration of `page`, or nil when the page holds no Velox XML with a pixel size in both axes (the file then falls
    /// through to the other conventions). A refused XML (`GuardedXML`) is no pixel size.
    public static func read(_ page: TIFFDirectory) -> TIFFVeloxCalibration? {
        guard let tag = page[34683], tag.type == 2 || tag.type == 7,
              let document = GuardedXML.document(String(decoding: tag.raw.reversed().drop(while: { $0 == 0 }).reversed(), as: UTF8.self)),
              let xNode = (try? document.nodes(forXPath: "/Metadata/BinaryResult/PixelSize/X"))?.first as? XMLElement,
              let yNode = (try? document.nodes(forXPath: "/Metadata/BinaryResult/PixelSize/Y"))?.first as? XMLElement,
              let xScale = Double(xNode.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
              let yScale = Double(yNode.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
              let xUnit = xNode.attribute(forName: "unit")?.stringValue,
              let yUnit = yNode.attribute(forName: "unit")?.stringValue else { return nil }
        if page[65452]?.integer == 3, xUnit == "m", yUnit == "m" {
            func agree(_ scale: Double, _ perCm: Double?) -> Bool {
                guard let perCm else { return true }
                guard perCm > 0, scale > 0, scale.isFinite else { return false }
                return abs(perCm - 0.01 / scale) <= 0.5 + Double(Float(perCm).ulp) / 2
            }
            if !agree(xScale, number(page[65450])) || !agree(yScale, number(page[65451])) { return .disagree }
        }
        return .calibrated(xScale: xScale, xUnit: xUnit, yScale: yScale, yUnit: yUnit)
    }

    /// The first value of a FLOAT, DOUBLE, RATIONAL (non-zero denominator) or integer tag.
    private static func number(_ tag: TIFFTag?) -> Double? {
        guard let tag, tag.count >= 1 else { return nil }
        switch tag.value {
        case .reals(let v): return v.first
        case .rationals(let v): return v.first.flatMap { $0.denominator != 0 ? Double($0.numerator) / Double($0.denominator) : nil }
        case .integers(let v): return v.first.map(Double.init)
        default: return nil
        }
    }
}
