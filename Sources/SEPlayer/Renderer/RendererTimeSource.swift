//
//  RendererTimeSource.swift
//  SEPlayer
//

import AVFoundation

/// Runs the clock the renderers play to, and starts and stops the audio with it.
///
/// `AVSampleBufferRenderSynchronizer` is one, for the renderers built on AVFoundation's sample buffer renderers. A
/// renderer only joins the kind it is built for; with another kind it follows the synchronizer's timebase.
public protocol PlaybackSynchronizer: AnyObject {
    /// The time the renderers play at.
    var timebase: CMTimebase { get }
    var rate: Float { get set }
    /// Whether a rate change waits until the audio has enough media data to play.
    var delaysRateChangeUntilHasSufficientMediaData: Bool { get set }
    func setRate(_ rate: Float, time: CMTime)
    func currentTime() -> CMTime
}

extension AVSampleBufferRenderSynchronizer: PlaybackSynchronizer {}

/// What the renderers play to.
///
/// By default the renderers join the player's synchronizer, which the player's clock runs with audio or without: the
/// synchronizer starts and changes the rate of the audio and the video together, holds both until they have enough
/// data, and accounts for the latency of the audio route, such as AirPlay. When a renderer provides the clock and
/// has no synchronizer, as for an audio output the synchronizer can't take, the renderers follow a timebase.
public enum RendererTimeSource {
    /// Renderers follow the timebase.
    case timebase(CMTimebase)
    /// Renderers that can join the synchronizer do; the others follow its timebase.
    case synchronizer(any PlaybackSynchronizer)

    /// The time the renderers play at, for timers.
    public var timebase: CMTimebase {
        switch self {
        case let .timebase(timebase): timebase
        case let .synchronizer(synchronizer): synchronizer.timebase
        }
    }

    /// The synchronizer to join, if any.
    public var synchronizer: (any PlaybackSynchronizer)? {
        if case let .synchronizer(synchronizer) = self { synchronizer } else { nil }
    }

    /// Whether both are the same timebase or the same synchronizer.
    public func isIdentical(to other: RendererTimeSource?) -> Bool {
        switch (self, other) {
        case let (.timebase(lhs), .timebase(rhs)?): lhs === rhs
        case let (.synchronizer(lhs), .synchronizer(rhs)?): lhs === rhs
        default: false
        }
    }
}
