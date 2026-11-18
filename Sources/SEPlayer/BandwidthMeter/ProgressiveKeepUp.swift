//
//  ProgressiveKeepUp.swift
//  SEPlayer
//

import Foundation

/// The bytes the media consumes over time, in 1024 equal buckets over its whole duration.
struct ProgressiveDemandProfile {
    static let bucketCount = 1024

    var bytes: [Int64]
    /// In seconds.
    var bucketDuration: Double

    /// Media consuming `bytesPerSecond` evenly.
    static func constant(bytesPerSecond: Double, duration: Double) -> ProgressiveDemandProfile {
        let bucketDuration = duration / Double(bucketCount)
        let bytes = Int64((bytesPerSecond * bucketDuration).rounded(.up))
        return ProgressiveDemandProfile(
            bytes: Array(repeating: max(1, bytes), count: bucketCount),
            bucketDuration: bucketDuration
        )
    }
}

/// Whether progressive playback is likely to keep up.
///
/// Walks the buckets after the buffered media. Each needs its bytes, inflated by the variability of the network, to
/// have arrived by its time; `additionalWait` gets how much longer to buffer for that.
///
/// - Parameters:
///   - networkBytesPerSecond: The moving average transfer rate, or the average while there is none.
///   - demandInflation: `1 + standardDeviation / average` of the transfer rate.
func progressiveIsLikelyToKeepUp(
    currentTime: Double,
    playableDurationAhead: Double,
    networkBytesPerSecond: Double,
    demandInflation: Float,
    profile: inout ProgressiveDemandProfile,
    additionalWait: inout Double
) -> Bool {
    if networkBytesPerSecond <= 0 { return false }
    let interval = profile.bucketDuration
    if interval == 0 { return false }
    precondition(profile.bytes.count == ProgressiveDemandProfile.bucketCount)

    // Repeated addition: floor(time / interval) differs at bucket boundaries.
    func bucketIndex(containing time: Double) -> Int {
        var index = 0
        var boundary = 0.0
        repeat {
            boundary = interval + boundary
            if boundary > time { break }
            index += 1
        } while index != ProgressiveDemandProfile.bucketCount - 1
        return index
    }

    let currentBucket = bucketIndex(containing: currentTime)
    let firstUnbufferedBucket = bucketIndex(containing: currentTime + playableDurationAhead)

    let creditedDuration = interval * Double(firstUnbufferedBucket - currentBucket)
    var credit = fma(creditedDuration, networkBytesPerSecond, 0.0)
    var wait = 0.0
    var likely = true

    for index in firstUnbufferedBucket ..< ProgressiveDemandProfile.bucketCount {
        let bytes = profile.bytes[index]
        // A bucket without bytes ends the walk.
        if bytes == 0 { break }

        // In Float32.
        let required = Double(Float(bytes) * demandInflation)
        if likely && credit > required {
            likely = true
        } else {
            likely = false
            if credit < required {
                wait = wait + (required - credit) / networkBytesPerSecond
                credit = required
            }
        }

        // The delivery of the bucket, less its uninflated bytes.
        credit = fma(interval, networkBytesPerSecond, -Double(bytes)) + credit
    }

    additionalWait = wait
    return likely
}
