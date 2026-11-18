//
//  ByteRateHistory.swift
//  SEPlayer
//

/// Transfer rates of progressive downloads.
///
/// Received bytes and the time they took go into samples of at least 100 ms, kept in a ring:
/// - the average is the bytes of the ring over its time, a ratio of totals, reported once the ring holds 500 ms or
///   1 MB;
/// - once the ring is full, every new sample moves a moving average 10% of the way to the ring's average;
/// - the deviation is of each completed sample's rate from the ring's average at the time, accumulated over the whole
///   history.
///
/// Not thread safe: guarded by its owner.
struct ByteRateHistory {
    /// In bytes per second.
    struct Rates {
        let average: Double
        let movingAverage: Double
        let standardDeviation: Double
    }

    private struct Entry {
        var duration: Int64 = 0
        var bytes: Int64 = 0
    }

    /// A sample is complete once it is longer than this, in nanoseconds.
    private static let sampleDuration: Int64 = 99_999_999

    private var ring: [Entry]
    private var index = 0
    private var completedCount = 0
    private var totalDuration: Int64 = 0
    private var totalBytes: Int64 = 0
    private var movingAverage = 0.0
    private var squaredDeviations = 0.0
    private var deviationCount = 0

    init(capacity: Int = 64) {
        ring = Array(repeating: Entry(), count: max(1, capacity))
    }

    mutating func reset() {
        self = ByteRateHistory(capacity: ring.count)
    }

    /// Adds `bytes` that took `duration` nanoseconds of delivery.
    mutating func add(bytes: Int64, duration: Int64) {
        ring[index].bytes += bytes
        ring[index].duration += duration
        totalBytes += bytes
        totalDuration += duration
        if ring[index].duration > Self.sampleDuration {
            nextSample()
        }
    }

    var rates: Rates {
        let average = totalDuration >= 500_000_000 || totalBytes >= 1_000_000
            ? Double(totalBytes) * 1e9 / Double(totalDuration)
            : 0
        let deviation = deviationCount > 0 ? (squaredDeviations / Double(deviationCount)).squareRoot() : 0
        return Rates(average: average, movingAverage: movingAverage, standardDeviation: deviation)
    }

    private mutating func nextSample() {
        let windowRate = Double(totalBytes) * 1e9 / Double(totalDuration)
        completedCount += 1
        if completedCount >= ring.count {
            movingAverage = movingAverage == 0 ? windowRate : windowRate * 0.1 + movingAverage * 0.9
        }

        let entry = ring[index]
        let deviation = Double(entry.bytes) * 1e9 / Double(entry.duration) - windowRate
        let squared = deviation * deviation
        if squaredDeviations <= .greatestFiniteMagnitude - squared {
            squaredDeviations += squared
            deviationCount += 1
        } else {
            squaredDeviations = squared
            deviationCount = 1
        }

        index = (index + 1) % ring.count
        totalBytes -= ring[index].bytes
        totalDuration -= ring[index].duration
        ring[index] = Entry()
    }
}
