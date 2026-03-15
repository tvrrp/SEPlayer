//
//  CueGroup.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

public struct CueGroup: Codable, Sendable {
    public let cues: [Cue]
    public let presentationTimeUs: Int64

    public static let emptyTimeZero = CueGroup(cues: [], presentationTimeUs: .zero)

    public init(cues: [Cue], presentationTimeUs: Int64) {
        self.cues = cues.sorted(by: { $0.zIndex < $1.zIndex })
        self.presentationTimeUs = presentationTimeUs
    }
}
