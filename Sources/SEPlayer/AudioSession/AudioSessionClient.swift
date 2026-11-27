//
//  AudioSessionClient.swift
//  SEPlayer
//

import SEPlayerCommon

/// A client of the shared audio session: a player, or one of the app's own.
public protocol AudioSessionClient: AnyObject, Sendable {
    /// Called on no particular thread when the session changes what the client's playback may do.
    func audioSessionController(_ controller: AudioSessionController, didSend command: AudioSessionCommand)
}

/// How a client uses the audio session now.
public struct AudioSessionUsage: Equatable, Sendable {
    /// A client that doesn't use the session.
    public static let unused = AudioSessionUsage(
        policy: .movie,
        hasMedia: false,
        wantsToPlay: false,
        isPlaying: false,
        isPaused: true,
        isInaudible: false
    )

    public var policy: AudioSessionPolicy
    /// Whether the client has media to play: a player isn't idle.
    public var hasMedia: Bool
    /// Whether the client plays, or will once it has buffered.
    public var wantsToPlay: Bool
    /// Whether the client plays now.
    public var isPlaying: Bool
    /// Whether the client was paused on request, outside of scrubbing, or played to the end.
    public var isPaused: Bool
    /// Whether what the client plays can't be heard: it is muted, or its volume is zero.
    public var isInaudible: Bool

    public init(
        policy: AudioSessionPolicy,
        hasMedia: Bool,
        wantsToPlay: Bool,
        isPlaying: Bool,
        isPaused: Bool,
        isInaudible: Bool
    ) {
        self.policy = policy
        self.hasMedia = hasMedia
        self.wantsToPlay = wantsToPlay
        self.isPlaying = isPlaying
        self.isPaused = isPaused
        self.isInaudible = isInaudible
    }
}

/// What the controller tells a client to do with its audible playback.
public enum AudioSessionCommand: Equatable {
    case play
    /// Wait, ready to play, as during an interruption.
    case wait
    case pause(PlayWhenReadyChangeReason)
}
