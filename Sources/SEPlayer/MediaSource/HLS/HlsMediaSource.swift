//
//  HlsMediaSource.swift
//  SEPlayer
//

import CoreMedia
import DataSource
import Extractor
import Foundation
import SEPlayerCommon

/// The playlists of an HLS stream, as the manifest of its timeline.
public struct HlsManifest {
    /// The multivariant playlist of the stream.
    public let multivariantPlaylist: HlsMultivariantPlaylist
    /// The primary media playlist the timeline is built from.
    public let mediaPlaylist: HlsMediaPlaylist
}

/// An HLS ``MediaSource``.
///
/// On-demand streams have a timeline of their whole duration. A live stream's timeline is its playlist's window, which
/// moves on as the playlist reloads: the period starts with the first playlist loaded, and the window sits where the
/// current playlist starts in it.
final class HlsMediaSource: BaseMediaSource, HlsPlaylistTracker.PrimaryPlaylistListener {
    private let queue: Queue
    private let loaderQueue: Queue
    private var mediaItem: MediaItem
    private let dataSourceFactory: DataSourceFactory
    private let decryptionMemoryPool: CMMemoryPool
    private let extractorFactory: HlsExtractorFactory
    private let subtitleParserFactory: SubtitleParserFactory
    private let allowChunklessPreparation: Bool
    private let loadErrorHandlingPolicy: LoadErrorHandlingPolicy

    private var playlistTracker: HlsPlaylistTracker?
    private var mediaTransferListener: TransferListener?
    /// The live configuration of the media item, with the target offset and playback speeds the playlist decides.
    private var liveConfiguration: MediaItem.LiveConfiguration
    private let timestampAdjusterProvider = TimestampAdjusterProvider()

    init(
        queue: Queue,
        loaderQueue: Queue,
        mediaItem: MediaItem,
        dataSourceFactory: DataSourceFactory,
        decryptionMemoryPool: CMMemoryPool,
        extractorFactory: HlsExtractorFactory? = nil,
        subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory(),
        allowChunklessPreparation: Bool = true,
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy()
    ) {
        self.queue = queue
        self.loaderQueue = loaderQueue
        self.mediaItem = mediaItem
        self.dataSourceFactory = dataSourceFactory
        self.decryptionMemoryPool = decryptionMemoryPool
        self.subtitleParserFactory = subtitleParserFactory
        self.extractorFactory = extractorFactory
            ?? DefaultHlsExtractorFactory(queue: loaderQueue, subtitleParserFactory: subtitleParserFactory)
        self.allowChunklessPreparation = allowChunklessPreparation
        self.loadErrorHandlingPolicy = loadErrorHandlingPolicy
        liveConfiguration = mediaItem.liveConfiguration
        super.init(queue: queue)
    }

    override func getMediaItem() -> MediaItem { mediaItem }

    override func prepareSourceInternal(mediaTransferListener: TransferListener?) throws {
        guard let url = mediaItem.localConfiguration?.url else {
            throw ErrorBuilder.illegalState()
        }
        self.mediaTransferListener = mediaTransferListener
        let playlistTracker = HlsPlaylistTracker(
            queue: queue,
            loaderQueue: loaderQueue,
            dataSourceFactory: dataSourceFactory,
            loadErrorHandlingPolicy: loadErrorHandlingPolicy,
            // The transfers of media reach the bandwidth meter: its estimate is the one the track selection starts with.
            startBitrateEstimate: { [weak mediaTransferListener = mediaTransferListener as? BandwidthMeter] in
                mediaTransferListener?.getBitrateEstimate()
            }
        )
        self.playlistTracker = playlistTracker
        playlistTracker.start(initialPlaylistUrl: url, primaryPlaylistListener: self)
    }

    override func maybeThrowSourceInfoRefreshError() throws {
        try playlistTracker?.maybeThrowPrimaryPlaylistRefreshError()
    }

    override func createPeriod(id: MediaPeriodId, allocator: Allocator, startPosition: CMTime) throws -> MediaPeriod {
        guard let playlistTracker else { throw ErrorBuilder.illegalState() }
        return HlsMediaPeriod(
            playlistTracker: playlistTracker,
            extractorFactory: extractorFactory,
            subtitleParserFactory: subtitleParserFactory,
            dataSourceFactory: dataSourceFactory,
            decryptionMemoryPool: decryptionMemoryPool,
            timestampAdjusterProvider: timestampAdjusterProvider,
            queue: queue,
            loaderQueue: loaderQueue,
            allowChunklessPreparation: allowChunklessPreparation,
            loadErrorHandlingPolicy: loadErrorHandlingPolicy,
            transferListener: mediaTransferListener,
            allocator: allocator
        )
    }

    override func release(mediaPeriod: MediaPeriod) {
        (mediaPeriod as? HlsMediaPeriod)?.release()
    }

    override func releaseSourceInternal() {
        playlistTracker?.stop()
        playlistTracker = nil
        timestampAdjusterProvider.reset()
        liveConfiguration = mediaItem.liveConfiguration
    }

    // MARK: - PrimaryPlaylistListener

    func onPrimaryPlaylistRefreshed(_ playlist: HlsMediaPlaylist) {
        guard let playlistTracker, let multivariantPlaylist = playlistTracker.multivariantPlaylist else {
            return
        }
        let manifest = HlsManifest(multivariantPlaylist: multivariantPlaylist, mediaPlaylist: playlist)

        let windowStartTime = playlist.hasProgramDateTime ? playlist.startTime : .invalid
        // A stream that only grows or never changes starts when its window starts.
        let presentationStartTime = playlist.playlistType == .event || playlist.playlistType == .vod
            ? windowStartTime
            : .invalid
        let timeline = playlistTracker.isLive
            ? makeLiveTimeline(
                playlist,
                presentationStartTime: presentationStartTime,
                windowStartTime: windowStartTime,
                manifest: manifest,
                initialStartTime: playlistTracker.initialStartTime
            )
            : makeOnDemandTimeline(
                playlist,
                presentationStartTime: presentationStartTime,
                windowStartTime: windowStartTime,
                manifest: manifest
            )

        do {
            try refreshSourceInfo(timeline: timeline)
        } catch {
            SELogger.error(.playlist, "HLS timeline refresh failed: \(error)")
        }
    }

    private func makeOnDemandTimeline(
        _ playlist: HlsMediaPlaylist,
        presentationStartTime: CMTime,
        windowStartTime: CMTime,
        manifest: HlsManifest
    ) -> SinglePeriodTimeline {
        SinglePeriodTimeline(
            presentationStartTime: presentationStartTime,
            windowStartTime: windowStartTime,
            elapsedRealtimeEpochOffset: .invalid,
            periodDuration: playlist.duration,
            windowDuration: playlist.duration,
            windowPositionInPeriod: .zero,
            windowDefaultStartPosition: defaultStartPosition(playlist),
            isSeekable: true,
            isDynamic: false,
            suppressPositionProjection: true,
            manifest: manifest,
            mediaItem: mediaItem,
            liveConfiguration: nil
        )
    }

    private func makeLiveTimeline(
        _ playlist: HlsMediaPlaylist,
        presentationStartTime: CMTime,
        windowStartTime: CMTime,
        manifest: HlsManifest,
        initialStartTime: CMTime
    ) -> SinglePeriodTimeline {
        let offsetFromInitialStartTime = playlist.startTime - initialStartTime
        // The period ends once the stream does.
        let periodDuration = playlist.hasEndTag ? offsetFromInitialStartTime + playlist.duration : .invalid
        let liveEdgeOffset = liveEdgeOffset(playlist)

        // The media item's offset, or the one taken from the first playlist: each refresh, and each switch of the
        // primary playlist, gives a slightly different live edge, and a target that followed it would keep moving.
        var targetLiveOffset = liveConfiguration.targetOffset.isValid
            ? liveConfiguration.targetOffset
            : targetLiveOffset(playlist, liveEdgeOffset: liveEdgeOffset)
        // Within the window, and behind the live edge.
        targetLiveOffset = min(max(targetLiveOffset, liveEdgeOffset), playlist.duration + liveEdgeOffset)
        updateLiveConfiguration(playlist, targetLiveOffset: targetLiveOffset)

        return SinglePeriodTimeline(
            presentationStartTime: presentationStartTime,
            windowStartTime: windowStartTime,
            elapsedRealtimeEpochOffset: .invalid,
            periodDuration: periodDuration,
            windowDuration: playlist.duration,
            windowPositionInPeriod: offsetFromInitialStartTime,
            windowDefaultStartPosition: liveWindowDefaultStartPosition(playlist, liveEdgeOffset: liveEdgeOffset),
            isSeekable: true,
            isDynamic: !playlist.hasEndTag,
            // An event playlist that asks to start inside it starts there, wherever the live edge is.
            suppressPositionProjection: playlist.playlistType == .event && playlist.hasPositiveStartOffset,
            manifest: manifest,
            mediaItem: mediaItem,
            liveConfiguration: liveConfiguration
        )
    }

    /// How far the end of the playlist is behind the wall clock, when the playlist dates its segments.
    private func liveEdgeOffset(_ playlist: HlsMediaPlaylist) -> CMTime {
        guard playlist.hasProgramDateTime else { return .zero }
        return CMTime(seconds: Date().timeIntervalSince1970, preferredTimescale: 1_000_000) - playlist.endTime
    }

    /// The offset from the live edge to play at: from #EXT-X-START, else the server's part hold back for a
    /// low-latency playlist, else its hold back, else three target durations.
    private func targetLiveOffset(_ playlist: HlsMediaPlaylist, liveEdgeOffset: CMTime) -> CMTime {
        let targetOffset: CMTime = if playlist.startOffset.isValid {
            playlist.duration - playlist.startOffset
        } else if playlist.isLowLatency, playlist.serverControl.partHoldBack.isValid {
            playlist.serverControl.partHoldBack
        } else if playlist.serverControl.holdBack.isValid {
            playlist.serverControl.holdBack
        } else {
            CMTimeMultiply(playlist.targetDuration, multiplier: 3)
        }
        return targetOffset + liveEdgeOffset
    }

    /// Takes the target offset into the live configuration. The playback speed stays at 1 unless the media item or
    /// the server asks for a live offset to keep.
    private func updateLiveConfiguration(_ playlist: HlsMediaPlaylist, targetLiveOffset: CMTime) {
        let itemConfiguration = mediaItem.liveConfiguration
        let disableSpeedAdjustment = itemConfiguration.minPlaybackSpeed == nil
            && itemConfiguration.maxPlaybackSpeed == nil
            && !playlist.serverControl.holdBack.isValid
            && !playlist.serverControl.partHoldBack.isValid
        liveConfiguration = liveConfiguration.buildUpon()
            .setTargetOffset(targetLiveOffset)
            .setMinPlaybackSpeed(disableSpeedAdjustment ? 1 : liveConfiguration.minPlaybackSpeed)
            .setMaxPlaybackSpeed(disableSpeedAdjustment ? 1 : liveConfiguration.maxPlaybackSpeed)
            .build()
    }

    /// Where live playback starts: #EXT-X-START, or the target offset behind the live edge; unless the start is
    /// precise, at the part it falls in that starts with a keyframe, or else at the segment it falls in.
    private func liveWindowDefaultStartPosition(_ playlist: HlsMediaPlaylist, liveEdgeOffset: CMTime) -> CMTime {
        let startPosition = playlist.startOffset.isValid
            ? playlist.startOffset
            : playlist.duration + liveEdgeOffset - liveConfiguration.targetOffset
        if playlist.preciseStart { return startPosition }

        let segment = playlist.segments.last { $0.relativeStartTime <= startPosition } ?? playlist.segments.first
        if playlist.isLowLatency {
            let parts = segment.map { startPosition < $0.endTime } == true ? segment?.parts ?? [] : playlist.trailingParts
            if let part = parts.last(where: { $0.isIndependent && !$0.isPreload && $0.relativeStartTime <= startPosition }) {
                return part.relativeStartTime
            }
        }
        return segment?.relativeStartTime ?? .zero
    }

    /// Where playback starts: #EXT-X-START, at the segment it falls in unless it asks to be precise.
    private func defaultStartPosition(_ playlist: HlsMediaPlaylist) -> CMTime {
        guard playlist.startOffset.isValid, !playlist.segments.isEmpty else {
            return .zero
        }
        if playlist.preciseStart || playlist.startOffset == playlist.duration {
            return playlist.startOffset
        }
        let segment = playlist.segments.last { $0.relativeStartTime <= playlist.startOffset } ?? playlist.segments[0]
        return segment.relativeStartTime
    }
}
