//
//  SEPlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import CoreMedia
@_exported import SEPlayerCommon

public protocol SEPlayer: Player {
    var clock: SEClock { get }
    var timebase: CMTimebase { get }
    /// The meter estimating the bandwidth the player loads with.
    var bandwidthMeter: BandwidthMeter { get }
    /// The format of the video being played, or `nil` without video.
    ///
    /// Unlike ``Player/currentTracks``, which selects every track an adaptive selection switches between, this is the
    /// one track that plays now. It changes a moment before the frames of the new format show.
    var videoFormat: Format? { get }
    /// The format of the audio being played, or `nil` without audio. It changes a moment before the new format plays.
    var audioFormat: Format? { get }
    var preloadConfiguration: PreloadConfiguration { get set }
    var pauseAtTheEndOfMediaItem: Bool { get set }
    /// Whether the user scrubs, as while a slider is held. While paused, every seek, an exact one too, then only needs
    /// to show its frame: HLS shows the keyframes of an I-frame playlist where media isn't buffered. Without it, only
    /// seeks that allow tolerance scrub; the seek after turning it off loads media to play.
    var scrubbingModeEnabled: Bool { get set }

    func set(mediaSources: [MediaSource])
    func set(mediaSources: [MediaSource], resetPosition: Bool)
    func set(mediaSources: [MediaSource], startMediaItemIndex: Int, startPosition: CMTime)
    func set(mediaSource: MediaSource)
    func set(mediaSource: MediaSource, startPosition: CMTime)
    func set(mediaSource: MediaSource, resetPosition: Bool)
    func append(mediaSource: MediaSource)
    func insert(mediaSource: MediaSource, at index: Int)
    func append(mediaSources: [MediaSource])
    func insert(mediaSources: [MediaSource], at index: Int)

    func set(shuffleOrder: ShuffleOrder)

    func addPeriodicTimeObserver(for interval: CMTime, queue: DispatchQueue, block: @escaping (CMTime) -> Void) throws -> AnyObject
    func addBoundaryTimeObserver(for times: [CMTime], queue: DispatchQueue, block: @escaping (CMTime) -> Void) throws -> AnyObject
    func removeTimeObserver(_ observer: AnyObject)

    func createMessage(handler: @escaping (_ messageType: Int, _ message: Any?) async -> Void) -> PlayerMessage
    func setVideoOutput(_ output: any VideoOutput)
    /// Removes `output`, and forgets the size it showed the picture at.
    func removeVideoOutput(_ output: any VideoOutput)
    /// Tells the player the size `output` shows the picture at, in the screen's pixels, or `nil` when it doesn't show
    /// it. An output is a ``VideoOutput``, or anything else that shows its picture, as Picture in Picture. With several
    /// outputs, the largest counts. Call it from any thread. The track selection limits its viewport to it while its
    /// parameters' ``TrackSelectionParameters/isViewportSizeLimitedByVideoOutputSize`` is on.
    func setVideoOutputSize(_ size: CGSize?, for output: AnyObject)

    /// The current cues.
    @MainActor var currentCues: CueGroup { get }

    /// Sets the parameters constraining the track selection, applying the selections they change as `application`
    /// says.
    ///
    /// With ``TrackSelectionApplication/immediate``, the buffered media of a changed selection is replaced right
    /// away: playback waits for the new media and keeps showing the last picture meanwhile. Use it for a choice the
    /// user makes, such as a quality.
    func setTrackSelectionParameters(_ parameters: TrackSelectionParameters, application: TrackSelectionApplication)
}

public extension SEPlayer {
    func addPeriodicTimeObserver(for interval: CMTime) throws -> AsyncStream<CMTime> {
        let (stream, continuation) = AsyncStream<CMTime>.makeStream()
        let token = try addPeriodicTimeObserver(for: interval, queue: .main) { time in
            continuation.yield(time)
        }
        continuation.onTermination = { _ in
            self.removeTimeObserver(token)
        }
        return stream
    }

    func addBoundaryTimeObserver(for times: [CMTime]) throws -> AsyncStream<CMTime> {
        let (stream, continuation) = AsyncStream<CMTime>.makeStream()
        let token = try addBoundaryTimeObserver(for: times, queue: .main) { time in
            continuation.yield(time)
        }
        continuation.onTermination = { _ in
            self.removeTimeObserver(token)
        }
        return stream
    }
}
