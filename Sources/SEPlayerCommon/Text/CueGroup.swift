//
//  CueGroup.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import CoreMedia

/// Represents the state of active `Cue`s at a particular time.
public struct CueGroup: Hashable, Sendable {
    /// The cues in this group.
    ///
    /// This list is in ascending order of priority. If any of the cue boxes overlap when displayed, the `Cue` nearer the
    /// end of the list should be shown on top.
    ///
    /// This list may be empty if the group represents a state with no cues.
    public let cues: [Cue]

    /// The presentation time of the `cues`.
    ///
    /// This time is an offset from the start of the current `Timeline.Period`.
    public let presentationTime: CMTime

    /// An empty group with no `Cue`s and presentation time of zero.
    public static let emptyTimeZero = CueGroup(cues: [], presentationTime: .zero)

    /// Creates a cue group.
    public init(cues: [Cue], presentationTime: CMTime) {
        self.cues = cues.sorted(by: { $0.zIndex < $1.zIndex })
        self.presentationTime = presentationTime
    }
}
