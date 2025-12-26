//
//  SinglePeriodAdTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.11.2025.
//

public final class SinglePeriodAdTimeline: ForwardingTimeline, @unchecked Sendable {
    private let adPlaybackState: AdPlaybackState

    init(contentTimeline: Timeline, adPlaybackState: AdPlaybackState) {
        self.adPlaybackState = adPlaybackState
        super.init(timeline: contentTimeline)
    }

    public override func getPeriod(periodIndex: Int, period: Period, setIds: Bool) -> Period {
        timeline.getPeriod(periodIndex: periodIndex, period: period, setIds: setIds)
        let durationUs = period.durationUs == .timeUnset ? adPlaybackState.contentDurationUs : period.durationUs
        period.set(
            id: period.id,
            uid: period.uid,
            windowIndex: period.windowIndex,
            durationUs: durationUs,
            positionInWindowUs: period.positionInWindowUs,
            adPlaybackState: adPlaybackState,
            isPlaceholder: period.isPlaceholder
        )

        return period
    }
}
