//
//  TIFFShapedSeries.swift
//  Role: tifffile 2026.9.20's `series_shaped` (with `pyramidize_series(reduced=True)`), the series rule for a TIFF whose
//        first page carries tifffile's own ImageDescription (`{"shape": [...]}`, optionally `axes`, `name`, `truncated` and
//        any user keys, or the old `shape=(...)` form). Every file tifffile writes with its default metadata is one.
//        RosettaSciIO 049e7d70 reads them through `TiffFile.series` (squeeze=None: a shaped series is not squeezed).
//        SubIFD series are refused by name. Where tifffile logs an error and returns no series (a bad description, a
//        shape that is not a multiple of the page) the caller falls to the generic rule, as tifffile does.
//

import Foundation
import FormatoCore

extension TIFFSignals {
    /// tifffile's `TiffPage.shaped_description` for the description in tag 270: a JSON object that contains `"shape":`, or a
    /// string that starts with `shape=`; a description that mentions `"mibi.` is not one.
    static func shapedDescription(_ page: TIFFDirectory) -> String? {
        guard let d = page[270]?.text, !d.isEmpty, !d.contains("\"mibi.") else { return nil }
        if d.hasPrefix("{") && d.contains("\"shape\":") { return d }
        if d.hasPrefix("shape=") { return d }
        return nil
    }

    /// What `shaped_description_metadata` gives: the shape, and the optional keys the series rule reads.
    struct ShapedDescription {
        var shape: [Int]
        var axes: String?
        /// `metadata.get('truncated')`: nil for a missing key and for JSON null (both are Python's None here).
        var truncated: Bool?
    }

    /// Parses a shaped description. nil where tifffile raises ValueError and the series rule gives up (not JSON, a bad old-style
    /// shape); throws where tifffile raises something else, which makes `TiffFile.series` raise (no `shape`, a `shape` that is not
    /// a list of non-negative integers, an `axes` that is not text).
    static func parseShapedDescription(_ text: String) throws -> ShapedDescription? {
        func refuse(_ why: String) -> FormatoReadError { .unsupported("The file's shaped description \(why); tifffile raises on it.") }
        if text.hasPrefix("shape=") {
            // Old form: `tuple(int(i) for i in description[7:-1].split(','))`.
            let body = String(text.dropFirst(7).dropLast())
            var shape: [Int] = []
            for part in body.split(separator: ",", omittingEmptySubsequences: false) {
                guard let v = formatoPythonInt(String(part)), let i = Int(exactly: v), i >= 0 else { return nil }
                shape.append(i)
            }
            return ShapedDescription(shape: shape, axes: nil, truncated: nil)
        }
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        guard let object = any as? [String: Any] else { throw refuse("is not a JSON object") }
        guard let rawShape = object["shape"] as? [Any] else { throw refuse("has no shape list") }
        var shape: [Int] = []
        for item in rawShape {
            guard let n = item as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n), n.int64Value >= 0,
                  let i = Int(exactly: n.int64Value) else { throw refuse("has a shape entry that is not a non-negative integer") }
            shape.append(i)
        }
        var axes: String?
        if let a = object["axes"] {
            guard let s = a as? String else { throw refuse("has axes that are not text") }
            axes = s
        }
        var truncated: Bool?
        if let t = object["truncated"], !(t is NSNull) {
            // Python truthiness of the JSON value.
            switch t {
            case let n as NSNumber: truncated = CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : n.doubleValue != 0
            case let s as String: truncated = !s.isEmpty
            case let a as [Any]: truncated = !a.isEmpty
            case let o as [String: Any]: truncated = !o.isEmpty
            default: truncated = true
            }
        }
        return ShapedDescription(shape: shape, axes: axes, truncated: truncated)
    }

    private static func product(_ values: [Int]) throws -> Int {
        var result = 1
        for v in values {
            let (r, o) = result.multipliedReportingOverflow(by: v)
            guard !o else { throw FormatoReadError.unsupported("The shaped series' shape is too large.") }
            result = r
        }
        return result
    }

    /// tifffile's `check_shape(page_shape, series_shape)`.
    static func checkShape(_ pageShape: [Int], _ seriesShape: [Int]) throws -> Bool {
        let pageSize = try product(pageShape), seriesSize = try product(seriesShape)
        if pageSize == 0 && seriesSize == 0 { return true }
        if pageSize == 0 || seriesSize == 0 { return false }
        if seriesSize % pageSize != 0 { return false }
        let series = Array(seriesShape.reversed())
        var a = 0
        var pi = 1, pj = 1
        for i in pageShape.reversed() {
            pi *= i
            for j in series[a...] {
                a += 1
                pj *= j
                if i == j || pi == pj { break }
                if j == 1 { continue }
                if pj != pi { return false }
            }
        }
        return true
    }

    /// tifffile's `reshape_axes(axes, shape, newshape)` (unknown axes 'Q'); nil where it raises ValueError; throws where it raises
    /// IndexError (an exhausted source indexed from the end past its first dimension), which tifffile does not swallow.
    static func reshapeAxes(_ axes: [Character], _ shape: [Int], _ newShape: [Int], file: String) throws -> [Character]? {
        guard axes.count == shape.count else { return nil }
        guard let size = try? product(shape), let newSize = try? product(newShape), size == newSize else { return nil }
        if axes.isEmpty && newShape.isEmpty { return [] }
        var newShape = newShape
        let lendiff = max(0, shape.count - newShape.count)
        if lendiff > 0 { newShape += [Int](repeating: 1, count: lendiff) }
        var i = shape.count - 1
        var prodns = 1, prods = 1
        var result: [Character] = []
        for ns in newShape.reversed() {
            prodns *= ns
            while i > 0 && shape[i] == 1 && ns != 1 { i -= 1 }
            let k = i >= 0 ? i : i + shape.count   // Python's negative index: an exhausted source reads from the end
            guard k >= 0 && k < shape.count else {
                throw FormatoReadError.unsupported("\(file): the shaped description's shape \(newShape) indexes past the page's dimensions (tifffile raises IndexError here).")
            }
            if ns == shape[k] && prodns == prods * shape[k] {
                prods *= shape[k]
                result.append(axes[k])
                i -= 1
            } else {
                result.append("Q")
            }
        }
        return Array(result.reversed().dropFirst(lendiff))
    }

    /// tifffile's `subresolution(a, b, p)` for series: the pyramid level of `b` below `a`, or nil.
    private static func subresolution(_ a: TIFFSeries, _ b: TIFFSeries, p: Int, n: Int = 16) -> Int? {
        guard a.axes == b.axes, a.dataType == b.dataType, a.shape.count == b.shape.count else { return nil }
        var level: Int?
        for ((ax, i), j) in zip(zip(a.axes.lowercased(), a.shape), b.shape) {
            if "xyz".contains(ax) {
                if let level {
                    var d = 1
                    for _ in 0..<level { d *= p }
                    if d > i { return nil }
                    if i / d != j && (i + d - 1) / d != j { return nil }
                } else {
                    var found: Int?
                    var d = 1
                    for r in 0..<n {
                        if r > 0 { d *= p }
                        if d > i { return nil }
                        if i / d == j || (i + d - 1) / d == j { found = r; break }
                    }
                    guard let found else { return nil }
                    level = found
                }
            } else if i != j {
                return nil
            }
        }
        return level
    }

    /// `series_shaped`: nil where tifffile gives no series (then the generic rule applies); throws where tifffile raises or
    /// where the series is outside what this reader takes (SubIFDs, pyramids, pages that disagree, data it cannot place).
    static func shapedSeries(_ file: TIFFFile) throws -> [TIFFSeries]? {
        let dirs = file.directories
        let size = file.data.count
        var series: [TIFFSeries] = []
        var reducedKeyframes: [Bool] = []
        var index = 0
        while index < dirs.count {
            let keyDir = dirs[index]
            guard let text = shapedDescription(keyDir), let parsed = try parseShapedDescription(text) else { return nil }
            guard keyDir[330] == nil else { throw FormatoReadError.unsupported("A shaped series with SubIFDs is not ported.") }
            let key = try TIFFPageLayout.of(keyDir, bigEndian: file.bigEndian, fileSize: size)
            let pageShape = key.samples > 1 ? [key.height, key.width, key.samples] : [key.height, key.width]
            let pageAxes: [Character] = key.samples > 1 ? ["Y", "X", "S"] : ["Y", "X"]
            let pageElements = try product(pageShape)
            let reshape = parsed.shape
            var axes: [Character]?
            var shape: [Int]?
            if let a = parsed.axes {
                if a.count == reshape.count { axes = Array(a); shape = reshape } else { axes = [] }
            }
            let total = try product(reshape)
            var pages = 1
            if total > 0 {
                let (q, r) = total.quotientAndRemainder(dividingBy: pageElements)
                guard r == 0 else { return nil }
                pages = q
            }
            var truncated = parsed.truncated
            var members = [index]
            if 1 < pages && pages <= dirs.count - index {
                let (bytes, o) = total.multipliedReportingOverflow(by: key.bytesPerSample)
                guard !o else { throw FormatoReadError.unsupported("The shaped series' shape is too large.") }
                if truncated == true {
                    pages = 1
                } else if key.isContiguous && keyDir.offset + bytes < dirs[index + 1].offset {
                    truncated = false
                } else {
                    truncated = false
                    members += Array((index + 1)..<(index + pages))
                }
            }
            // `append`
            var outShape = shape, outAxes = axes, outReshape = reshape
            let failed = !(try checkShape(pageShape, reshape))
            if failed || outAxes == nil || outShape == nil {
                var s = pageShape
                var a = pageAxes
                if members.count > 1 { s.insert(members.count, at: 0); a.insert("Q", at: 0) }
                outShape = s; outAxes = a
                if failed { outReshape = s }
            }
            var curShape = outShape!, curAxes = outAxes!
            let curSize = try product(curShape), reSize = try product(outReshape)
            if key.isContiguous && reSize > curSize && reSize % curSize == 0 {
                curAxes.insert("Q", at: 0)
                curShape.insert(reSize / curSize, at: 0)
            }
            if let reshaped = try reshapeAxes(curAxes, curShape, outReshape, file: formatoDisplayFileName(file.path)) { curAxes = reshaped; curShape = outReshape }
            // The images the series reads: one per page, or (one page, data following it) a virtual run.
            let images = try product(curShape) / pageElements
            guard try product(curShape) % pageElements == 0 else { throw FormatoReadError.unsupported("A shaped series whose shape is not a whole number of pages.") }
            let layouts: [TIFFPageLayout]
            var virtual: Int?
            if members.count == images {
                layouts = try members.map { m in
                    let l = try TIFFPageLayout.of(dirs[m], bigEndian: file.bigEndian, fileSize: size)
                    guard l.width == key.width, l.height == key.height, l.dataType == key.dataType, l.samples == key.samples else {
                        throw FormatoReadError.unsupported("A page of a shaped series differs from its first page.")
                    }
                    return l
                }
            } else if members.count == 1 && key.isContiguous {
                let (bytes, o) = images.multipliedReportingOverflow(by: key.pageBytes)
                guard !o, key.stripOffsets[0] <= size - bytes else { throw TIFFError.truncated("The shaped series claims more bytes than the file holds.") }
                layouts = [key]; virtual = images
            } else {
                throw FormatoReadError.unsupported("A shaped series of \(images) images over \(members.count) pages that are not stored contiguously.")
            }
            series.append(TIFFSeries(axes: String(curAxes), shape: curShape, dataType: key.dataType, pages: layouts, virtualCount: virtual,
                                     firstDirectory: index))
            reducedKeyframes.append(Self.isReduced(keyDir))
            index += pages
        }
        // pyramidize_series(reduced=True): a later series whose first page is a reduced image and one pyramid step below
        // the previous level of an earlier series joins it as a level and is no series of its own.
        var i = 0
        while i < series.count {
            var level = series[i]
            var factor: Int?
            var j = i + 1
            while j < series.count {
                guard reducedKeyframes[j] else { j += 1; continue }
                if factor == nil {
                    factor = [2, 3, 4].first { subresolution(level, series[j], p: $0) == 1 }
                    guard factor != nil else { j += 1; continue }
                } else if subresolution(level, series[j], p: factor!) != 1 {
                    j += 1; continue
                }
                level = series[j]
                series.remove(at: j)
                reducedKeyframes.remove(at: j)
            }
            i += 1
        }
        return series.isEmpty ? nil : series
    }

    /// tifffile's `TiffPage.is_reduced`: NewSubfileType bit 0, or SubfileType 2 when NewSubfileType is 0.
    static func isReduced(_ page: TIFFDirectory) -> Bool {
        let new = page[254]?.integer ?? 0
        if new != 0 { return new & 1 != 0 }
        return page[255]?.integer == 2
    }
}
