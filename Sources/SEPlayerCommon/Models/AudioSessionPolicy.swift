//
//  AudioSessionPolicy.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import AVFAudio

/// How a player shares the app's audio session with the other players of the app and with the audio of other apps.
///
/// The players of an app share one audio session. The player that needs the most of it decides how it is set up:
/// audible playback that stops other audio wins over audible playback that ducks it, which wins over playback that
/// mixes with it, as muted playback does. A player takes its share once it plays, not while it buffers to start, and
/// keeps it while it stalls, seeks or scrubs. Paused on request or muted, it can give its share back, so that the
/// audio of other apps resumes.
public struct AudioSessionPolicy: Hashable, @unchecked Sendable {
    /// What audible playback does to the audio of other apps.
    public enum Audibility: Hashable, Sendable {
        /// Other audio stops while the player plays, as for a movie.
        case exclusive
        /// Other audio plays on, quieter.
        case duckOthers
        /// Other audio plays on alongside.
        case mixWithOthers
    }

    /// What happens to the audio of other apps once the player stops being audible.
    public enum Release: Hashable, Sendable {
        /// The player keeps its share: other audio stays as it was, as while a movie is paused for a moment.
        case hold
        /// The player gives its share back: other apps' audio may resume.
        case shareWithOthers
    }

    /// What audible playback does to other audio.
    public var audibility: Audibility
    /// What happens when the player is paused on request or reaches the end. A pause while scrubbing, or because the
    /// audio route went away, keeps the share.
    public var whenPaused: Release
    /// What happens when the player is muted, or its volume is zero.
    public var whenMuted: Release
    #if !os(macOS)
    /// The mode of the session while this player decides how it is set up.
    public var mode: AVAudioSession.Mode
    /// How the session's audio is routed while this player decides it with exclusive playback; mixing playback is
    /// always routed by default. `.longFormAudio` routes it with other long-form audio, such as to AirPlay.
    public var routeSharingPolicy: AVAudioSession.RouteSharingPolicy
    #endif
    /// Whether audible playback pauses when the route it played on goes away, as when headphones are unplugged.
    public var pausesWhenRouteIsLost: Bool

    #if !os(macOS)
    public init(
        audibility: Audibility = .exclusive,
        whenPaused: Release = .hold,
        whenMuted: Release = .shareWithOthers,
        mode: AVAudioSession.Mode = .moviePlayback,
        routeSharingPolicy: AVAudioSession.RouteSharingPolicy = .longFormAudio,
        pausesWhenRouteIsLost: Bool = true
    ) {
        self.audibility = audibility
        self.whenPaused = whenPaused
        self.whenMuted = whenMuted
        self.mode = mode
        self.routeSharingPolicy = routeSharingPolicy
        self.pausesWhenRouteIsLost = pausesWhenRouteIsLost
    }
    #else
    /// macOS has no audio session to share: the policy only tells when playback pauses.
    public init(
        audibility: Audibility = .exclusive,
        whenPaused: Release = .hold,
        whenMuted: Release = .shareWithOthers,
        pausesWhenRouteIsLost: Bool = true
    ) {
        self.audibility = audibility
        self.whenPaused = whenPaused
        self.whenMuted = whenMuted
        self.pausesWhenRouteIsLost = pausesWhenRouteIsLost
    }
    #endif

    /// A movie: other audio stops while it plays and stays stopped while it is paused. Muted, it lets other audio
    /// play.
    public static let movie = AudioSessionPolicy()

    // Video that plays along with whatever else plays, as in a feed: it mixes with other audio, and lets it be as
    // soon as it pauses.
    #if !os(macOS)
    public static let mixWithOthers = AudioSessionPolicy(
        audibility: .mixWithOthers,
        whenPaused: .shareWithOthers,
        whenMuted: .shareWithOthers,
        mode: .moviePlayback,
        routeSharingPolicy: .default,
        pausesWhenRouteIsLost: false
    )
    #else
    public static let mixWithOthers = AudioSessionPolicy(
        audibility: .mixWithOthers,
        whenPaused: .shareWithOthers,
        whenMuted: .shareWithOthers,
        pausesWhenRouteIsLost: false
    )
    #endif
}
