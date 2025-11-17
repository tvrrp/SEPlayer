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

    public override func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
        timeline.getPeriod(periodIndex: periodIndex, period: &period, setIds: setIds)
        let durationUs = period.durationUs == .timeUnset ? adPlaybackState.contentDurationUs : period.durationUs
        period.adPlaybackState = adPlaybackState
        period.durationUs = durationUs
        return period
    }
}
