//
//  BlockBufferCacheHandler.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import CoreMedia
import Foundation

/// Downloaded bytes kept in memory, as sorted runs of contiguous bytes.
///
/// Bytes are stored as the `DispatchData` URLSession delivered them, so nothing is copied, neither
/// when storing nor when reading.
final class BlockBufferCacheHandler {
    private struct Run {
        var start: Int
        var data: DispatchData
        var end: Int { start + data.count }
    }

    private var runs: [Run] = []

    var size: Int {
        runs.reduce(0) { $0 + $1.data.count }
    }

    /// Where the cached bytes starting at `offset` end; `offset` itself if it is not cached.
    func endOfCachedBytes(from offset: Int) -> Int {
        guard let run = runs.first(where: { $0.start <= offset && offset < $0.end }) else {
            return offset
        }
        return run.end
    }

    func contains(_ range: Range<Int>) -> Bool {
        range.isEmpty || endOfCachedBytes(from: range.lowerBound) >= range.upperBound
    }

    /// Returns the bytes in `range`, which must be cached.
    func read(_ range: Range<Int>) throws -> CMBlockBuffer {
        guard let run = runs.first(where: { $0.start <= range.lowerBound && range.upperBound <= $0.end }) else {
            throw DataSourceError(reason: .unknown, message: "Reading bytes that are not cached")
        }

        let bytes = run.data.subdata(in: (range.lowerBound - run.start)..<(range.upperBound - run.start))
        let blockBuffer = try CMBlockBuffer()
        var appendError: (any Error)?

        bytes.enumerateBytes { region, _, stop in
            do {
                try blockBuffer.append(
                    buffer: UnsafeMutableRawBufferPointer(mutating: UnsafeRawBufferPointer(region)),
                    deallocator: { _, _ in withExtendedLifetime(bytes) {} }
                )
            } catch {
                appendError = error
                stop = true
            }
        }

        if let appendError { throw appendError }
        return blockBuffer
    }

    /// Stores `bytes` at `offset`, joining them with the runs they touch or overlap.
    func append(_ bytes: DispatchData, at offset: Int) {
        guard !bytes.isEmpty else { return }
        runs.append(Run(start: offset, data: bytes))
        runs.sort { $0.start < $1.start }

        var joined: [Run] = []
        for run in runs {
            guard var last = joined.last, run.start <= last.end else {
                joined.append(run)
                continue
            }

            if run.end > last.end {
                last.data.append(run.data.subdata(in: (last.end - run.start)..<run.data.count))
                joined[joined.count - 1] = last
            }
        }
        runs = joined
    }

    /// Drops every byte outside `ranges`.
    func removeAll(except ranges: [Range<Int>]) {
        let old = runs
        runs = []

        for run in old {
            for range in ranges {
                let lower = max(run.start, range.lowerBound)
                let upper = min(run.end, range.upperBound)
                guard lower < upper else { continue }
                append(run.data.subdata(in: (lower - run.start)..<(upper - run.start)), at: lower)
            }
        }
    }
}
