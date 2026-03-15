//
//  CuesWithTiming.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import SEPlayerCommon

public struct CuesWithTiming: Codable {
    public let cues: [Cue]
    public let startTimeUs: Int64
    public let durationUs: Int64
    public let endTimeUs: Int64

    public init(cues: [Cue], startTimeUs: Int64, durationUs: Int64) {
        self.cues = cues
        self.startTimeUs = startTimeUs
        self.durationUs = durationUs
        self.endTimeUs = if startTimeUs == .timeUnset || durationUs == .timeUnset {
            .timeUnset
        } else {
            startTimeUs + durationUs
        }
    }
}
