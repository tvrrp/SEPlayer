//
//  SinglePeriodAdTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.11.2025.
//

import SEPlayerCommon

public final class SinglePeriodAdTimeline: ForwardingTimeline, @unchecked Sendable {
    private let adPlaybackState: AdPlaybackState

    init(contentTimeline: Timeline, adPlaybackState: AdPlaybackState) {
        self.adPlaybackState = adPlaybackState
        super.init(timeline: contentTimeline)
    }

    public override func getPeriod(periodIndex: Int, period: Period, setIds: Bool) -> Period {
        timeline.getPeriod(periodIndex: periodIndex, period: period, setIds: setIds)
        let duration = !period.duration.isValid ? adPlaybackState.contentDuration : period.duration
        period.set(
            id: period.id,
            uid: period.uid,
            windowIndex: period.windowIndex,
            duration: duration,
            positionInWindow: period.positionInWindow,
            adPlaybackState: adPlaybackState,
            isPlaceholder: period.isPlaceholder
        )

        return period
    }
}
