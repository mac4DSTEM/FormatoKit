//
//  VeloxEventStore.swift
//  Role: A Velox spectrum stream's geometry, frame selection, sparse event store (CSR) and its decoder.
//        Moved out of VeloxEMDReader.swift unchanged; the format notes are at the top of that file.
//

import Foundation
import FormatoCore

// MARK: - Stream geometry, event store

/// The raster of one spectrum image: `ny` rows of `nx` pixels, `channels` per spectrum.
public nonisolated struct VeloxStreamGeometry: Equatable, Sendable {
    public let ny: Int
    public let nx: Int
    public let channels: Int
    public var pixelsPerFrame: Int { ny * nx }
    package init(ny: Int, nx: Int, channels: Int) {
        self.ny = ny; self.nx = nx; self.channels = channels
    }
}

/// Which frames of the stream are summed.
public nonisolated enum VeloxFrameSelection: Equatable, Sendable {
    /// rsciio's default: frames `0 ..< endFramePosition` of `SpectrumImageSettings`
    /// (all frames when that is absent). DEVIATION-free by construction, and equal
    /// to "every frame" on every public file and on the owner's file.
    case recordedDefault
    /// Every frame the stream holds, whatever `SpectrumImageSettings` says.
    case all
    case range(Range<Int>)
}

/// The per-pixel sparse spectrum image, frames summed: CSR over pixels (row-major,
/// `pixel = y * nx + x`). Channels inside a pixel ascend; each channel appears once.
public nonisolated struct VeloxEventStore: Sendable {
    public let geometry: VeloxStreamGeometry
    /// `pixelCount + 1` offsets into `channelIndex` / `counts`.
    public let rowOffsets: [Int]
    public let channelIndex: [UInt16]
    public let counts: [UInt32]
    /// The frames summed, as indices into the stream.
    public let frameRange: Range<Int>
    /// Frames whose every pixel was reached (inside `frameRange`).
    public let completeFrames: Int
    /// Pixels (from the first) that a further, partial frame also reached: those
    /// pixels carry `completeFrames + 1` frames of dose, the rest `completeFrames`.
    /// rsciio sums such a stopped acquisition without a flag; this reader reports it.
    public let partialFramePixels: Int
    /// Stream values >= `channels` that are not the marker: skipped and counted.
    /// DEVIATION: rsciio's jitted loop indexes past the array for them (undefined).
    public let outOfRangeValues: Int
    /// False when the streams of a multi-detector file did not all end in the same place.
    public let streamsAgreeOnCoverage: Bool

    public var pixelCount: Int { geometry.pixelsPerFrame }
    /// Total counts (events) in the store: the stream's non-marker value count
    /// inside the frame range (prediction P4).
    public var totalCounts: Int { counts.reduce(0) { $0 + Int($1) } }
    package var distinctEntries: Int { channelIndex.count }
    package var storageBytes: Int {
        rowOffsets.count * MemoryLayout<Int>.stride + channelIndex.count * 2 + counts.count * 4
    }

    /// Frames of dose that `pixel` received.
    public func framesCovering(pixel: Int) -> Int {
        completeFrames + (pixel < partialFramePixels ? 1 : 0)
    }

    /// One pixel's spectrum, dense.
    public func spectrum(pixel: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: geometry.channels)
        for k in rowOffsets[pixel]..<rowOffsets[pixel + 1] { out[Int(channelIndex[k])] = counts[k] }
        return out
    }

    /// The whole cube, dense, `(ny, nx, channels)` row-major. Small files only (tests, parity).
    public func denseCounts() -> [UInt32] {
        let c = geometry.channels
        var out = [UInt32](repeating: 0, count: pixelCount * c)
        for p in 0..<pixelCount {
            for k in rowOffsets[p]..<rowOffsets[p + 1] { out[p * c + Int(channelIndex[k])] = counts[k] }
        }
        return out
    }

    /// The summed spectrum over every pixel.
    public func summedSpectrum() -> [UInt64] {
        var out = [UInt64](repeating: 0, count: geometry.channels)
        for k in 0..<channelIndex.count { out[Int(channelIndex[k])] += UInt64(counts[k]) }
        return out
    }
}

/// The pure decode: the rsciio state machine, run over blocks of stream values.
/// It carries the pixel index and frame number across blocks, so a 408 M-value stream
/// is never held in memory (the owner's 1456 stream is 816 MB; this Mac panicked once
/// on a file bigger than RAM).
package nonisolated enum VeloxStreamDecoder {
    package static let pixelMarker: UInt16 = 65535

    /// A supplier of one stream's values, block by block. Called twice per build
    /// (count, then fill), so it must be restartable.
    /// The visitor answers whether it wants more blocks: a frame range that is done stops the read.
    package typealias BlockSource = ((UnsafeBufferPointer<UInt16>) throws -> Bool) throws -> Void

    private struct Cursor {
        var navigation = 0
        var frame = 0
        var done = false
    }

    private protocol EventVisitor {
        mutating func event(pixel: Int, channel: UInt16)
    }

    /// rsciio `_fill_array_with_stream_sum_frames`, line for line:
    ///
    ///     if navigation_index == ny*nx { navigation_index = 0; frame += 1; if frame == last_frame { break } }
    ///     if value != 65535 { if first_frame <= frame { count it } } else { navigation_index += 1 }
    ///
    /// The frame turnover is tested on the value AFTER a frame's last marker, so a
    /// stream that ends on its last marker never opens a further frame.
    @inline(__always)
    private static func scan<V: EventVisitor>(
        _ block: UnsafeBufferPointer<UInt16>, frameSize: Int, first: Int, last: Int,
        cursor: inout Cursor, visitor: inout V
    ) {
        var navigation = cursor.navigation
        var frame = cursor.frame
        for value in block {
            if navigation == frameSize {
                navigation = 0
                frame += 1
                if frame == last { cursor.done = true; break }
            }
            if value != pixelMarker {
                if first <= frame { visitor.event(pixel: navigation, channel: value) }
            } else {
                navigation += 1
            }
        }
        cursor.navigation = navigation
        cursor.frame = frame
    }

    private struct CountingVisitor: EventVisitor {
        var perPixel: UnsafeMutablePointer<Int>
        let channels: Int
        var outOfRange = 0
        mutating func event(pixel: Int, channel: UInt16) {
            if Int(channel) < channels { perPixel[pixel] += 1 } else { outOfRange += 1 }
        }
    }

    private struct FillVisitor: EventVisitor {
        var cursorPerPixel: UnsafeMutablePointer<Int>
        var events: UnsafeMutablePointer<UInt16>
        let channels: Int
        mutating func event(pixel: Int, channel: UInt16) {
            guard Int(channel) < channels else { return }
            events[cursorPerPixel[pixel]] = channel
            cursorPerPixel[pixel] += 1
        }
    }

    /// Builds the event store from one or more detector streams, summing them.
    /// `frames` must be a validated, non-empty range (the caller resolves `.recordedDefault`).
    /// `cancelled` is polled at every block and between the phases (count, scatter, sort, compact); a true answer throws
    /// `FormatoCancelled` and nothing built is kept. `progress` (monotone, ends at 1) counts finished stream passes (two per
    /// stream, count then scatter) and the finished store; a caller wanting block resolution reports it from its block
    /// sources, as `VeloxEMDReader.readSpectrumImage` does.
    package static func buildEventStore(
        streams: [BlockSource], geometry: VeloxStreamGeometry, frames: Range<Int>,
        cancelled: @Sendable () -> Bool = FormatoCancellation.task,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> VeloxEventStore {
        try FormatoCancellation.check(cancelled)
        guard !frames.isEmpty, frames.lowerBound >= 0 else {
            throw VeloxEMDError.frameRangeInvalid("\(frames) is empty or negative")
        }
        let pixels = geometry.pixelsPerFrame
        guard pixels > 0, geometry.channels > 0 else {
            throw VeloxEMDError.cannotDetermineGrid("\(geometry.ny) x \(geometry.nx) pixels, \(geometry.channels) channels")
        }
        let first = frames.lowerBound, last = frames.upperBound

        // Pass 1: events per pixel, over every stream.
        var perPixel = [Int](repeating: 0, count: pixels + 1)
        var outOfRange = 0
        var ends: [(frame: Int, navigation: Int, done: Bool)] = []
        let passesTotal = 2 * streams.count
        var passesDone = 0
        try perPixel.withUnsafeMutableBufferPointer { counts in
            for stream in streams {
                var cursor = Cursor()
                var visitor = CountingVisitor(perPixel: counts.baseAddress!, channels: geometry.channels)
                try stream { block in
                    try FormatoCancellation.check(cancelled)
                    if cursor.done { return false }
                    scan(block, frameSize: pixels, first: first, last: last, cursor: &cursor, visitor: &visitor)
                    return !cursor.done
                }
                outOfRange += visitor.outOfRange
                ends.append((cursor.frame, cursor.navigation, cursor.done))
                passesDone += 1
                progress?(Double(passesDone) / Double(passesTotal + 1))
            }
        }

        // Bucket offsets (exclusive prefix sum), then pass 2: scatter the channels.
        var bucketStart = [Int](repeating: 0, count: pixels + 1)
        var running = 0
        for p in 0..<pixels { bucketStart[p] = running; running += perPixel[p] }
        bucketStart[pixels] = running
        let totalEvents = running

        let events = UnsafeMutablePointer<UInt16>.allocate(capacity: max(totalEvents, 1))
        defer { events.deallocate() }
        var fillCursor = Array(bucketStart[0..<pixels])
        try fillCursor.withUnsafeMutableBufferPointer { cursorPerPixel in
            for stream in streams {
                var cursor = Cursor()
                var visitor = FillVisitor(cursorPerPixel: cursorPerPixel.baseAddress!, events: events, channels: geometry.channels)
                try stream { block in
                    try FormatoCancellation.check(cancelled)
                    if cursor.done { return false }
                    scan(block, frameSize: pixels, first: first, last: last, cursor: &cursor, visitor: &visitor)
                    return !cursor.done
                }
                passesDone += 1
                progress?(Double(passesDone) / Double(passesTotal + 1))
            }
        }
        try FormatoCancellation.check(cancelled)

        // Sort each pixel's channels in place, count the distinct ones, then compact to CSR.
        var rowOffsets = [Int](repeating: 0, count: pixels + 1)
        var distinct = 0
        for p in 0..<pixels {
            if p & 0xFFFF == 0 { try FormatoCancellation.check(cancelled) }   // every 65536 pixels, never per value
            var segment = UnsafeMutableBufferPointer(start: events + bucketStart[p], count: perPixel[p])
            segment.sort()
            var n = 0
            var previous: UInt16?
            for value in segment where value != previous { n += 1; previous = value }
            distinct += n
            rowOffsets[p + 1] = distinct
        }
        var channelIndex = [UInt16](repeating: 0, count: distinct)
        var counts = [UInt32](repeating: 0, count: distinct)
        channelIndex.withUnsafeMutableBufferPointer { channelOut in
            counts.withUnsafeMutableBufferPointer { countOut in
                var w = 0
                for p in 0..<pixels {
                    let segment = UnsafeBufferPointer(start: events + bucketStart[p], count: perPixel[p])
                    var i = 0
                    while i < segment.count {
                        let channel = segment[i]
                        var j = i + 1
                        while j < segment.count && segment[j] == channel { j += 1 }
                        channelOut[w] = channel
                        countOut[w] = UInt32(j - i)
                        w += 1
                        i = j
                    }
                }
            }
        }

        // Coverage of the first stream: what a stopped acquisition left in its last frame.
        let head = ends.first ?? (0, 0, false)
        var complete = 0, partial = 0
        if head.done {
            complete = last - first
        } else if head.frame >= first {
            // A frame whose LAST pixel's marker is absent is complete: Velox streams may end on that pixel's
            // events with no closing 65535 (every stream of example_velox_EELS_EDS.emd: 319 markers for 320
            // pixels; rsciio `_fei_stream_readers.py` stores the trailing pixel, ceil(319 / 320) = 1 frame).
            // A stream that stops exactly one pixel short, with no events after the last marker, cannot be told
            // from that case and is read as complete too.
            if head.navigation == pixels || head.navigation == pixels - 1 {
                complete = head.frame - first + 1
            } else {
                complete = head.frame - first
                partial = head.navigation
            }
        }
        let agree = ends.allSatisfy { $0.frame == head.frame && $0.navigation == head.navigation && $0.done == head.done }
        progress?(1)
        return VeloxEventStore(
            geometry: geometry, rowOffsets: rowOffsets, channelIndex: channelIndex, counts: counts,
            frameRange: frames, completeFrames: complete, partialFramePixels: partial,
            outOfRangeValues: outOfRange, streamsAgreeOnCoverage: agree)
    }

    /// The same decode over in-memory arrays (tests, small files).
    package static func buildEventStore(
        arrays: [[UInt16]], geometry: VeloxStreamGeometry, frames: Range<Int>
    ) throws -> VeloxEventStore {
        let sources: [BlockSource] = arrays.map { array in
            { visit in try array.withUnsafeBufferPointer { _ = try visit($0) } }
        }
        return try buildEventStore(streams: sources, geometry: geometry, frames: frames)
    }
}
