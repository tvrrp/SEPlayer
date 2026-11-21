//
//  AdaptiveTrackSelection.swift
//  SEPlayer
//
//  Created by tvrrp on 19.02.2026.
//

import CoreMedia
import SEPlayerCommon

/// A bandwidth based adaptive ``SETrackSelection``: the selected track is the best one the network sustains.
///
/// A track fits when its bitrate, at the playback speed, is within the safe part of the predicted bandwidth. The
/// selection moves down as soon as the selected track no longer fits. It moves up only when the bandwidth exceeds the
/// next higher track's bitrate by a margin, and the next chunk of the new track loads before the buffer runs out.
class AdaptiveTrackSelection: BaseTrackSelection {
    /// Factory for ``AdaptiveTrackSelection`` instances.
    final class Factory: SETrackSelectionFactory {
        private let bandwidthFraction: Float

        /// - Parameter bandwidthFraction: The fraction of the safe bandwidth the selection plans with.
        init(bandwidthFraction: Float = 1) {
            self.bandwidthFraction = bandwidthFraction
        }

        func createTrackSelections(
            definitions: [SETrackSelectionDefinition?],
            bandwidthMeter: BandwidthMeter,
            mediaPeriodId: MediaPeriodId,
            timeline: Timeline
        ) -> [SETrackSelection?] {
            definitions.map { definition -> SETrackSelection? in
                guard let definition, !definition.tracks.isEmpty else {
                    return nil
                }
                if definition.tracks.count == 1 {
                    return FixedTrackSelection(
                        group: definition.group,
                        track: definition.tracks[0],
                        type: definition.type
                    )
                }
                return AdaptiveTrackSelection(
                    group: definition.group,
                    tracks: definition.tracks,
                    type: definition.type,
                    bandwidthMeter: bandwidthMeter,
                    bandwidthFraction: bandwidthFraction
                )
            }
        }
    }

    override var selectedIndex: Int { _selectedIndex }
    override var selectedReason: TrackSelectionReason { reason }
    override var selectionData: Any? { nil }

    private let bandwidthMeter: BandwidthMeter
    private let bandwidthFraction: Float

    private var playbackSpeed: Float = 1
    private var _selectedIndex = 0
    private var reason: TrackSelectionReason = .unknown

    init(
        group: TrackGroup,
        tracks: [Int],
        type: TrackSelectionType,
        bandwidthMeter: BandwidthMeter,
        bandwidthFraction: Float
    ) {
        self.bandwidthMeter = bandwidthMeter
        self.bandwidthFraction = bandwidthFraction
        super.init(group: group, tracks: tracks, type: type)
        _selectedIndex = determineIdealSelectedIndex(now: CMClock.hostTimeClock.time, chunkDuration: .invalid)
    }

    override func enable() {
        reason = .unknown
    }

    override func playbackSpeedDidChange(_ playbackSpeed: Float) {
        self.playbackSpeed = playbackSpeed
    }

    override func loadsQuickly(bits: Double) -> Bool? {
        guard let bandwidth = bandwidthMeter.predict(expectedTransferBytes: Int(bits / 8))?.safeBitrate else {
            return nil
        }
        return bits / (Double(bandwidth) * Double(bandwidthFraction)) <= Self.quickLoadDuration
    }

    override func updateSelectedTrack(
        playbackPosition: CMTime,
        bufferedDuration: CMTime,
        availableDuration: CMTime,
        queue: [MediaChunk],
        mediaChunkIterators: [MediaChunkIterator]
    ) {
        let now = CMClock.hostTimeClock.time
        let chunkDuration = lastChunkDuration(queue: queue)

        if reason == .unknown {
            // A selection that replaces another while media is buffered goes on from the track that loads now.
            if let lastFormat = queue.last?.trackFormat, let index = indexOf(format: lastFormat) {
                reason = .adaptive
                _selectedIndex = index
            } else {
                // The first update: the initial selection may be stale, nothing of it was loaded yet.
                reason = .initial
                _selectedIndex = determineIdealSelectedIndex(now: now, chunkDuration: chunkDuration)
                SELogger.info(
                    .trackSelection,
                    "Starting with track \(_selectedIndex) of \(length): \(format(for: _selectedIndex))"
                )
                return
            }
        }

        var previousSelectedIndex = _selectedIndex
        var previousReason = reason
        // The last chunk tells what was really loaded: the selection may have changed after it started.
        if let lastFormat = queue.last?.trackFormat, let index = indexOf(format: lastFormat) {
            previousSelectedIndex = index
            previousReason = queue.last?.trackSelectionReason ?? previousReason
        }

        var newSelectedIndex = determineIdealSelectedIndex(now: now, chunkDuration: chunkDuration)
        // Formats are sorted by decreasing bitrate: a lower index is a higher quality.
        let switchesUp = newSelectedIndex < previousSelectedIndex
        if switchesUp, !isTrackExcluded(index: previousSelectedIndex, now: now),
           !canSwitchUp(
               from: previousSelectedIndex,
               to: newSelectedIndex,
               now: now,
               chunkDuration: chunkDuration,
               bufferedDuration: bufferedDuration
           ) {
            newSelectedIndex = previousSelectedIndex
        }

        // The queue may still end with the old track: only a change of the selection itself is news.
        if newSelectedIndex != _selectedIndex {
            let direction = newSelectedIndex < _selectedIndex ? "up" : "down"
            SELogger.info(
                .trackSelection,
                "Switching \(direction) from track \(_selectedIndex) to \(newSelectedIndex), "
                    + "buffered \(bufferedDuration.seconds)s: \(format(for: newSelectedIndex))"
            )
        }

        reason = newSelectedIndex == previousSelectedIndex ? previousReason : .adaptive
        _selectedIndex = newSelectedIndex
    }

    // MARK: - Private

    /// The best track within the bandwidth, or the lowest one allowed.
    private func determineIdealSelectedIndex(now: CMTime, chunkDuration: CMTime) -> Int {
        var lowestBitrateAllowedIndex = 0
        for index in 0 ..< length where !isTrackExcluded(index: index, now: now) {
            let format = format(for: index)
            if requiredBitrate(format) <= bandwidth(for: format, chunkDuration: chunkDuration) {
                return index
            }
            lowestBitrateAllowedIndex = index
        }
        return lowestBitrateAllowedIndex
    }

    /// A switch up needs a margin of bandwidth over the next higher track, and the next chunk of the new track must
    /// load before the buffer runs out.
    private func canSwitchUp(
        from current: Int,
        to candidate: Int,
        now: CMTime,
        chunkDuration: CMTime,
        bufferedDuration: CMTime
    ) -> Bool {
        let nextHigher = (0 ..< current).reversed().first { !isTrackExcluded(index: $0, now: now) }
        guard let nextHigher else { return false }
        let nextFormat = format(for: nextHigher)
        let required = Double(requiredBitrate(nextFormat)) * Self.switchUpMargin
        guard Double(bandwidth(for: nextFormat, chunkDuration: chunkDuration)) >= required else {
            return false
        }

        guard chunkDuration.isNumeric, bufferedDuration.isNumeric else { return true }
        let candidateFormat = format(for: candidate)
        let candidateBandwidth = Double(bandwidth(for: candidateFormat, chunkDuration: chunkDuration))
        let chunkBits = Double(requiredBitrate(candidateFormat)) * chunkDuration.seconds
        // What the network delivers before the buffer runs out must cover the chunk.
        return bufferedDuration.seconds * candidateBandwidth > chunkBits
    }

    /// The bitrate a format needs at the playback speed, in bits per second.
    private func requiredBitrate(_ format: AnyFormat) -> Int {
        Int((Float(format.bitrate ?? 0) * max(1, abs(playbackSpeed))).rounded())
    }

    /// The bandwidth to plan with for chunks of `format`: the safe part of the prediction. Chunks are larger at higher
    /// bitrates, so the latency of their requests weighs less.
    private func bandwidth(for format: AnyFormat, chunkDuration: CMTime) -> Int {
        let averageBitrate = format.averageBitrate ?? format.bitrate ?? 0
        let chunkBytes = chunkDuration.isNumeric && averageBitrate > 0
            ? Int(chunkDuration.seconds * Double(averageBitrate) / 8)
            : nil
        let bandwidth = bandwidthMeter.predict(expectedTransferBytes: chunkBytes)?.safeBitrate
            ?? bandwidthMeter.getBitrateEstimate()
        return Int(Float(bandwidth) * bandwidthFraction)
    }

    private func lastChunkDuration(queue: [MediaChunk]) -> CMTime {
        guard let last = queue.last, last.startTime.isNumeric, last.endTime.isNumeric else {
            return .invalid
        }
        return last.endTime - last.startTime
    }
}

private extension AdaptiveTrackSelection {
    /// How much more bandwidth than the next higher track needs a switch up takes.
    static let switchUpMargin = 1.1
    /// How long a transfer may take to count as quick, in seconds.
    static let quickLoadDuration = 0.5
}
