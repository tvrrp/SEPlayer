//
//  AdaptiveTrackSelection.swift
//  SEPlayer
//
//  Created by tvrrp on 19.02.2026.
//

import CoreGraphics

class AdaptiveTrackSelection: BaseTrackSelection {
    final class Factory: SETrackSelectionFactory {
        private let minDurationForQualityIncreaseMs: Int64
        private let maxDurationForQualityDecreaseMs: Int64
        private let minDurationToRetainAfterDiscardMs: Int64
        private let maxSizeToDiscard: CGSize
        private let bandwidthFraction: Float
        private let bufferedFractionToLiveEdgeForQualityIncrease: Float
        private let clock: SEClock

        init(
            minDurationForQualityIncreaseMs: Int64 = 10_000,
            maxDurationForQualityDecreaseMs: Int64 = 25_000,
            minDurationToRetainAfterDiscardMs: Int64 = 25_000,
            maxSizeToDiscard: CGSize = CGSize(width: 1279, height: 719),
            bandwidthFraction: Float = 0.7,
            bufferedFractionToLiveEdgeForQualityIncrease: Float = 0.75,
            clock: SEClock = DefaultSEClock.shared,
        ) {
            self.minDurationForQualityIncreaseMs = minDurationForQualityIncreaseMs
            self.maxDurationForQualityDecreaseMs = maxDurationForQualityDecreaseMs
            self.minDurationToRetainAfterDiscardMs = minDurationToRetainAfterDiscardMs
            self.maxSizeToDiscard = maxSizeToDiscard
            self.bandwidthFraction = bandwidthFraction
            self.bufferedFractionToLiveEdgeForQualityIncrease = bufferedFractionToLiveEdgeForQualityIncrease
            self.clock = clock
        }

        func createTrackSelections(
            definitions: [SETrackSelectionDefinition?],
            bandwidthMeter: BandwidthMeter,
            mediaPeriodId: MediaPeriodId,
            timeline: Timeline
        ) -> [SETrackSelection?] {
            var selections = Array<SETrackSelection?>(repeating: nil, count: definitions.count)

            for (index, definition) in definitions.enumerated() {
                guard let definition, !definition.tracks.isEmpty else {
                    continue
                }

                if definition.tracks.count == 1 {
                    selections[index] = FixedTrackSelection(
                        group: definition.group,
                        track: definition.tracks[0],
                        type: definition.type
                    )
                } else {
                    assertionFailure("Not supported")
                    selections[index] = nil
                }
            }

            return selections
        }
    }
}
