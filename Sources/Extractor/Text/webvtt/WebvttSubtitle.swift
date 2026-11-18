//
//  WebvttSubtitle.swift
//  SEPlayer
//

import CoreMedia
import SEPlayerCommon

/// The cues of a WebVTT file, as events where cues start and end.
struct WebvttSubtitle: Subtitle {
    let eventTimes: [CMTime]
    private let cueInfos: [WebvttCueInfo]

    init(cueInfos: [WebvttCueInfo]) {
        self.cueInfos = cueInfos
        eventTimes = Set(cueInfos.flatMap { [$0.startTime, $0.endTime] }).sorted()
    }

    /// The cues that show at `time`. Cues without a line stack from the bottom up, in the order they started.
    func cues(at time: CMTime) -> [Cue] {
        var cues: [Cue] = []
        var cuesWithUnsetLine: [WebvttCueInfo] = []
        for cueInfo in cueInfos where cueInfo.startTime <= time && time < cueInfo.endTime {
            if cueInfo.cue.line == nil {
                cuesWithUnsetLine.append(cueInfo)
            } else {
                cues.append(cueInfo.cue)
            }
        }
        // Stable: cues that start together keep the order of the file.
        let sorted = cuesWithUnsetLine.enumerated().sorted {
            $0.element.startTime != $1.element.startTime ? $0.element.startTime < $1.element.startTime : $0.offset < $1.offset
        }
        for (index, cueInfo) in sorted.map(\.element).enumerated() {
            cues.append(cueInfo.cue.buildUpon().setLine(.number(-1 - index)).build())
        }
        return cues
    }
}
