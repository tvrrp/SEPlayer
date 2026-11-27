//
//  AudioSessionRequest.swift
//  SEPlayer
//

import AVFAudio

/// How a user of the audio session other than a player needs it, as one that records.
///
/// The user activates the session with ``AudioSessionController/activate(_:id:)`` instead of configuring it itself,
/// so that the players know of it. With `AVCaptureSession`, set `automaticallyConfiguresApplicationAudioSession` to
/// `false`: otherwise the capture session configures the session itself, as a change made outside the controller.
public struct AudioSessionRequest: Equatable, @unchecked Sendable {
    /// What players do while a request holds the session.
    public enum PlayerBehavior: Comparable, Sendable {
        /// Players play on, with the session configured for the request.
        case keepPlaying
        /// Players wait, and play on once no request holds the session.
        case waitAndResume
        /// Players pause, and stay paused.
        case pause
    }

    public var category: AVAudioSession.Category
    public var mode: AVAudioSession.Mode
    public var options: AVAudioSession.CategoryOptions
    public var routeSharingPolicy: AVAudioSession.RouteSharingPolicy
    /// What players do while the request holds the session. Of several requests, the strictest applies.
    public var players: PlayerBehavior

    public init(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode = .default,
        options: AVAudioSession.CategoryOptions = [],
        routeSharingPolicy: AVAudioSession.RouteSharingPolicy = .default,
        players: PlayerBehavior = .pause
    ) {
        self.category = category
        self.mode = mode
        self.options = options
        self.routeSharingPolicy = routeSharingPolicy
        self.players = players
    }
}
