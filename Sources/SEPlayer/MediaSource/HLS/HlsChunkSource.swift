//
//  HlsChunkSource.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.hls.HlsChunkSource
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

// swiftlint:disable file_length

import CoreMedia
import DataSource
import Foundation
import SEPlayerCommon

/// Source of HLS (possibly adaptive) chunks.
///
/// Runs on the player queue.
final class HlsChunkSource {
    /// Chunk holder that allows the scheduling of retries.
    struct ChunkHolder {
        /// The chunk to be loaded next.
        var chunk: Chunk?
        /// Indicates that the end of the stream has been reached.
        var endOfStream = false
        /// Indicates that the chunk source is waiting for the referred playlist to be refreshed.
        var playlistUrl: URL?
    }

    /// Whether a preload hint's chunk is still what the playlist announces.
    enum PublicationState {
        /// The playlist still announces the part with a preload hint.
        case preload
        /// The playlist lists the part: the chunk is final.
        case published
        /// The playlist no longer has the part the hint announced: the chunk is to go.
        case removed
    }

    /// The track group of the variants or renditions the source loads.
    let trackGroup: TrackGroup
    /// The selection of a track of ``trackGroup``, or `nil` for its first track.
    var trackSelection: SETrackSelection? {
        didSet {
            // The playlist of the old selection stops reloading by itself.
            if let oldValue, trackSelection.map({ !$0.isEquals(to: oldValue) }) ?? true {
                deactivatePlaylistForSelectedTrack(of: oldValue)
            }
        }
    }

    /// Whether the chunks set the timeline of their discontinuity for the other renditions.
    var isTimestampMaster = false
    /// Whether only the frame at the load position is needed. With I-frame variants the source then loads the keyframe
    /// of an I-frame playlist at the position, and nothing after it.
    ///
    /// The I-frame playlist is the best whose keyframe loads quickly, no better than the selected variant.
    var isScrubbing = false {
        didSet {
            guard isScrubbing != oldValue else { return }
            if isScrubbing {
                startScrubbing()
            } else {
                stopScrubbing()
            }
        }
    }

    /// Whether ``isScrubbing`` makes the source load I-frames.
    var scrubsWithIFrames: Bool { !scrubbingIFrameVariants.isEmpty }

    private let extractorFactory: HlsExtractorFactory
    private let playlistTracker: HlsPlaylistTracker
    private let playlistUrls: [URL]
    private let playlistFormats: [AnyFormat]
    private let iFrameVariants: [HlsMultivariantPlaylist.Variant]
    /// The closed captions in the variants, as the playlist declares them; `nil` if it doesn't.
    private let closedCaptionFormats: [TextFormat]?
    private let dataSourceFactory: DataSourceFactory
    private let timestampAdjusterProvider: TimestampAdjusterProvider
    private let loaderQueue: Queue
    private let transferListener: TransferListener?
    /// The memory of decrypted segments.
    private let decryptionMemoryPool: CMMemoryPool

    /// The keys loaded last, the most recent last: segments that rotate keys use few at a time.
    private var keyCache = KeyCache(capacity: 4)
    /// Where the live edge of the selected playlist is, in period time; `.invalid` for a stream that ended.
    private var liveEdgeTimeInPeriod: CMTime = .invalid
    /// The error that stops the source from providing chunks until it is reset.
    private var unrecoverableError: Error?
    private var expectedPlaylistUrl: URL?
    /// Whether the playlist the source waits for failed to load.
    private var seenExpectedPlaylistError = false
    private var independentSegments = false
    /// The I-frame playlist scrubbing loads keyframes from.
    private var scrubbingIFrameUrl: URL?
    /// The I-frame playlist scrubbing moves to once it has loaded.
    private var pendingScrubbingIFrameUrl: URL?
    /// The I-frame playlists loaded ahead of scrubbing.
    private var preloadedIFramePlaylistUrls = Set<URL>()
    /// I-frame playlists that failed to load: scrubbing loads whole segments rather than wait for them.
    private var failedIFramePlaylistUrls = Set<URL>()

    init(
        extractorFactory: HlsExtractorFactory,
        playlistTracker: HlsPlaylistTracker,
        playlistUrls: [URL],
        playlistFormats: [AnyFormat],
        dataSourceFactory: DataSourceFactory,
        decryptionMemoryPool: CMMemoryPool,
        timestampAdjusterProvider: TimestampAdjusterProvider,
        loaderQueue: Queue,
        transferListener: TransferListener?,
        iFrameVariants: [HlsMultivariantPlaylist.Variant] = [],
        closedCaptionFormats: [TextFormat]? = nil
    ) throws {
        self.iFrameVariants = iFrameVariants
        self.closedCaptionFormats = closedCaptionFormats
        self.extractorFactory = extractorFactory
        self.playlistTracker = playlistTracker
        self.playlistUrls = playlistUrls
        self.playlistFormats = playlistFormats
        self.dataSourceFactory = dataSourceFactory
        self.decryptionMemoryPool = decryptionMemoryPool
        self.timestampAdjusterProvider = timestampAdjusterProvider
        self.loaderQueue = loaderQueue
        self.transferListener = transferListener
        trackGroup = try TrackGroup(formats: playlistFormats)
    }

    /// The index in ``trackGroup`` of the media playlist.
    func trackIndex(of playlistUrl: URL) -> Int? {
        playlistUrls.firstIndex(of: playlistUrl)
    }

    /// If the source is currently having difficulty providing chunks, throws the error.
    func maybeThrowError() throws {
        if let unrecoverableError { throw unrecoverableError }
        if let expectedPlaylistUrl, seenExpectedPlaylistError {
            try playlistTracker.maybeThrowPlaylistRefreshError(url: expectedPlaylistUrl)
        }
    }

    /// Whether the source loads the chunks of the media playlist.
    func obtainsChunks(forPlaylist url: URL) -> Bool {
        playlistUrls.contains(url) || iFrameVariants.contains { $0.url == url }
    }

    /// The tracks a failed load can fall back to: the other tracks of the selection that aren't excluded.
    func fallbackOptions() -> FallbackOptions {
        let now = CMClock.hostTimeClock.time
        let length = trackSelection?.length ?? 1
        let excluded = trackSelection.map { selection in
            (0 ..< selection.length).filter { selection.isTrackExcluded(index: $0, now: now) }.count
        } ?? 0
        return FallbackOptions(
            numberOfLocations: 1,
            numberOfExcludedLocations: 0,
            numberOfTracks: length,
            numberOfExcludedTracks: excluded
        )
    }

    /// Excludes the track of a chunk that failed to load, so the selection switches to another.
    ///
    /// - Returns: Whether the track was excluded.
    func maybeExcludeTrack(of chunk: Chunk, exclusionDuration: CMTime) -> Bool {
        let groupIndex = (chunk as? HlsMediaChunk).flatMap { trackIndex(of: $0.playlistUrl) }
            ?? chunk.trackFormat.flatMap { trackGroup.indexOf(format: $0) }
        guard let trackSelection, let groupIndex,
              let index = trackSelection.indexOf(indexInTrackGroup: groupIndex) else {
            return false
        }
        return trackSelection.excludeTrack(index: index, exclusionDuration: exclusionDuration)
    }

    /// Called when a media playlist failed to load.
    ///
    /// - Parameter exclusionDuration: How long to exclude the track of the playlist for, or `.invalid` not to.
    /// - Returns: Whether the track was excluded, or didn't need to be: the source doesn't play the playlist, or
    ///   isn't asked to exclude it.
    func onPlaylistError(url: URL, exclusionDuration: CMTime) -> Bool {
        if iFrameVariants.contains(where: { $0.url == url }) {
            failedIFramePlaylistUrls.insert(url)
            if url == expectedPlaylistUrl { setExpectedPlaylistUrl(nil) }
            return true
        }
        guard let groupIndex = trackIndex(of: url) else { return true }
        // Without a selection the source loads the first track, which nothing can stand in for.
        let index = trackSelection.map { $0.indexOf(indexInTrackGroup: groupIndex) } ?? groupIndex
        guard let index else { return true }
        seenExpectedPlaylistError = seenExpectedPlaylistError || url == expectedPlaylistUrl
        guard exclusionDuration.isValid else { return true }
        guard let trackSelection else { return false }
        return trackSelection.excludeTrack(index: index, exclusionDuration: exclusionDuration)
            && playlistTracker.excludeMediaPlaylist(url: url, exclusionDuration: exclusionDuration)
    }

    /// Resets the source: chunks will be loaded from the selected track again.
    func reset() {
        deactivatePlaylistForSelectedTrack(of: trackSelection)
        unrecoverableError = nil
    }

    /// Returns the next chunk to load.
    ///
    /// - Parameters:
    ///   - playbackPosition: The current playback position.
    ///   - loadPosition: The position from which data should be loaded.
    ///   - largestReadPosition: The latest time the renderers read samples of: a switch can't splice in before it.
    ///   - queue: The queue of buffered media chunks.
    ///   - allowEndOfStream: Whether the end of the stream can be signaled.
    func getNextChunk(
        playbackPosition: CMTime,
        loadPosition: CMTime,
        largestReadPosition: CMTime = .invalid,
        queue: [HlsMediaChunk],
        allowEndOfStream: Bool
    ) -> ChunkHolder {
        if isScrubbing, queue.isEmpty {
            adaptScrubbingIFramePlaylist(loadPosition: loadPosition)
        }
        if isScrubbing, let scrubbingIFrameUrl {
            return nextIFrameChunk(playlistUrl: scrubbingIFrameUrl, loadPosition: loadPosition, queue: queue)
        }

        var holder = ChunkHolder()
        let previous = queue.last
        // After the start: during it, the request would take a connection and bandwidth from the first segments.
        if queue.count >= 2 { preloadScrubbingIFramePlaylist() }

        // Without independent segments a switch loads the previous chunk's segment again, so it doesn't count as
        // buffered.
        var bufferedDuration = loadPosition - playbackPosition
        // How much more there is to load before the live edge: the selection can't plan with more buffer than that.
        var timeToLiveEdge = liveEdgeTimeInPeriod.isNumeric ? liveEdgeTimeInPeriod - playbackPosition : CMTime.invalid
        if let previous, !independentSegments {
            bufferedDuration = bufferedDuration - previous.duration
            if timeToLiveEdge.isNumeric { timeToLiveEdge = timeToLiveEdge - previous.duration }
        }
        let oldTrackIndex = previous.flatMap { playlistUrls.firstIndex(of: $0.playlistUrl) }
        trackSelection?.updateSelectedTrack(
            playbackPosition: playbackPosition,
            bufferedDuration: max(.zero, bufferedDuration),
            availableDuration: timeToLiveEdge.isNumeric ? max(.zero, timeToLiveEdge) : .invalid,
            queue: queue,
            mediaChunkIterators: makeMediaChunkIterators(loadPosition: loadPosition)
        )

        var trackIndex = selectedTrackIndex
        var switchingTrack = previous != nil && oldTrackIndex != trackIndex
        var playlistUrl = playlistUrls[trackIndex]

        guard playlistTracker.isSnapshotValid(url: playlistUrl),
              var playlist = playlistTracker.getPlaylistSnapshot(url: playlistUrl, isForPlayback: true) else {
            SELogger.debug(.hls, "Waiting for the playlist of variant \(trackIndex)")
            setExpectedPlaylistUrl(playlistUrl)
            holder.playlistUrl = playlistUrl
            return holder
        }

        var startOffset = self.startOffset(of: playlist)
        var nextPosition = nextPosition(
            previous: previous,
            switchingTrack: switchingTrack,
            playlist: playlist,
            startOffset: startOffset,
            loadPosition: loadPosition
        )

        // A switch that would fall behind the live window, or start before what the renderers already read, is put
        // off: the old track goes on.
        if switchingTrack, let previous, let oldTrackIndex,
           shouldKeepCurrentTrack(
               oldTrackIndex: oldTrackIndex,
               playlist: playlist,
               position: nextPosition,
               startOffset: startOffset,
               largestReadPosition: largestReadPosition
           ),
           let oldPlaylist = playlistTracker.getPlaylistSnapshot(url: previous.playlistUrl, isForPlayback: true) {
            SELogger.debug(.hls, "Keeping variant \(oldTrackIndex) rather than switching to \(trackIndex)")
            trackIndex = oldTrackIndex
            switchingTrack = false
            playlistUrl = previous.playlistUrl
            playlist = oldPlaylist
            startOffset = self.startOffset(of: playlist)
            nextPosition = self.nextPosition(
                previous: previous,
                switchingTrack: false,
                playlist: playlist,
                startOffset: startOffset,
                loadPosition: loadPosition
            )
        }
        independentSegments = playlist.hasIndependentSegments
        liveEdgeTimeInPeriod = playlist.hasEndTag ? .invalid : startOffset + playlist.duration
        // The playlist of the track switched away from stops reloading by itself.
        if switchingTrack, let previous {
            playlistTracker.deactivatePlaylistForPlayback(url: previous.playlistUrl)
        }

        guard let position = nextPosition else {
            SELogger.debug(
                .hls,
                "The playlist of variant \(trackIndex) ends before \(loadPosition.seconds)s: waiting for a newer one"
            )
            setExpectedPlaylistUrl(playlistUrl)
            holder.playlistUrl = playlistUrl
            return holder
        }
        let mediaSequence = position.mediaSequence

        if mediaSequence < playlist.mediaSequence {
            // The segment left the window of the live playlist.
            SELogger.warning(
                .hls,
                "Segment \(mediaSequence) left the live window, which starts at \(playlist.mediaSequence)"
            )
            unrecoverableError = BehindLiveWindowError()
            return holder
        }

        guard let segment = SegmentReference(position, in: playlist) else {
            if playlist.hasEndTag {
                if allowEndOfStream || playlist.segments.isEmpty {
                    SELogger.debug(.hls, "End of the stream of variant \(trackIndex)")
                    holder.endOfStream = true
                }
            } else {
                SELogger.debug(.hls, "\(position) of variant \(trackIndex) isn't in the playlist yet")
                setExpectedPlaylistUrl(playlistUrl)
                holder.playlistUrl = playlistUrl
            }
            return holder
        }
        setExpectedPlaylistUrl(nil)
        let initSegment = segment.initializationSegment

        // A key goes before the chunk that needs it.
        let keyChunk = makeKeyChunkIfNeeded(
            initializationSegment: initSegment,
            encryption: segment.encryption,
            trackIndex: trackIndex
        )
        if let keyChunk {
            holder.chunk = keyChunk
            return holder
        }

        // A chunk that starts with a keyframe, after a switch or a load that didn't complete, replaces what is queued
        // from where it starts only if it overlaps it; otherwise its samples follow on.
        let isIndependent = segment.isIndependent(in: playlist)
        let startTime = startOffset + segment.relativeStartTime
        let followsPrevious = previous.map { $0.playlistUrl == playlistUrl && $0.isLoadCompleted } ?? true
        let shouldSpliceIn = if let previous, !followsPrevious {
            !isIndependent || startTime < previous.endTime
        } else {
            false
        }

        let discontinuitySequence = playlist.discontinuitySequence + segment.relativeDiscontinuitySequence
        // Segments don't change: their bytes stay for a later read, as of an initialization section or a keyframe.
        // The server answers a preload hint once it has the part, or as it makes it: not at the network's speed.
        let dataSpec = Self.makeDataSpec(
            url: segment.url,
            offset: segment.byteRangeOffset,
            length: segment.byteRangeLength,
            flags: segment.isPreload ? [.keepLoadedBytes, .mightNotUseFullNetworkSpeed] : .keepLoadedBytes
        )
        let mediaKey = segmentKey(segment.encryption, mediaSequence: mediaSequence)

        logChunk(
            segment,
            trackIndex: trackIndex,
            oldTrackIndex: switchingTrack ? oldTrackIndex : nil,
            startTime: startTime,
            discontinuitySequence: discontinuitySequence,
            isEncrypted: mediaKey != nil
        )
        holder.chunk = HlsMediaChunk(
            uid: Self.nextChunkUid(),
            dataSpec: dataSpec,
            format: selectedFormat(ofTrack: trackIndex),
            trackSelectionReason: trackSelection?.selectedReason ?? .initial,
            trackSelectionData: trackSelection?.selectionData,
            startTime: startTime,
            endTime: startTime + segment.duration,
            mediaSequence: mediaSequence,
            partIndex: segment.position.partIndex,
            discontinuitySequence: discontinuitySequence,
            playlistUrl: playlistUrl,
            initDataSpec: initSegment.map(Self.makeDataSpec(initializationSegment:)),
            mediaKey: mediaKey,
            initKey: segmentKey(initSegment?.encryption, mediaSequence: mediaSequence),
            isMasterTimestampSource: isTimestampMaster,
            timestampAdjuster: timestampAdjusterProvider.adjuster(discontinuitySequence: discontinuitySequence),
            previousChunk: previous,
            playlistFormat: playlistFormats[trackIndex],
            shouldSpliceIn: shouldSpliceIn,
            isIndependent: isIndependent,
            isPreload: segment.isPreload,
            hasGapTag: segment.hasGapTag,
            loaderQueue: loaderQueue,
            dataSourceFactory: dataSourceFactory,
            decryptionMemoryPool: decryptionMemoryPool,
            extractorFactory: extractorFactory,
            transferListener: transferListener,
            closedCaptionFormats: closedCaptionFormats
        )
        return holder
    }

    /// Called when a chunk loaded.
    func onChunkLoadCompleted(_ chunk: Chunk) {
        if let mediaChunk = chunk as? MediaChunk {
            trackSelection?.chunkLoaded(mediaChunk)
        }
        if let keyChunk = chunk as? HlsEncryptionKeyChunk {
            if let key = keyChunk.key {
                SELogger.debug(.decryption, "Loaded the key \(keyChunk.dataSpec.url.lastPathComponent)")
                keyCache.insert(key, for: keyChunk.dataSpec.url)
            } else {
                SELogger.warning(.decryption, "The key \(keyChunk.dataSpec.url.lastPathComponent) loaded without a key")
            }
        }
    }

    /// Whether the part a preload hint announced, and the chunk loads, is still what the playlist has there.
    func publicationState(of chunk: HlsMediaChunk) -> PublicationState {
        guard chunk.isPreload, let partIndex = chunk.partIndex, let mediaSequence = chunk.chunkIndex,
              let playlist = playlistTracker.getPlaylistSnapshot(url: chunk.playlistUrl, isForPlayback: false) else {
            return .published
        }
        // The segment left the playlist: the part was there.
        guard mediaSequence >= playlist.mediaSequence else { return .published }
        let parts = playlist.parts(ofMediaSequence: mediaSequence)
        guard parts.indices.contains(partIndex) else { return .removed }
        let part = parts[partIndex]
        if part.isPreload { return .preload }
        return part.url == chunk.dataSpec.url ? .published : .removed
    }

    /// How many of the queued chunks to keep: the selection may drop those of a lower quality than it would load now.
    func preferredQueueSize(playbackPosition: CMTime, queue: [HlsMediaChunk]) -> Int {
        guard unrecoverableError == nil, let trackSelection, trackSelection.length > 1 else {
            return queue.count
        }
        return trackSelection.evaluateQueueSize(playbackPosition: playbackPosition, queue: queue)
    }

    /// The position of a sync sample near the position. Each segment starts with one when they are independent, and
    /// each segment of an I-frame playlist is one while scrubbing.
    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        if isScrubbing, let scrubbingIFrameUrl,
           let playlist = playlistTracker.getPlaylistSnapshot(url: scrubbingIFrameUrl, isForPlayback: false),
           !playlist.segments.isEmpty {
            return Self.adjustedSeekPosition(
                position,
                in: playlist,
                startOffset: startOffset(of: playlist),
                seekParameters: seekParameters
            )
        }

        let playlistUrl = playlistUrls[selectedTrackIndex]
        guard let playlist = playlistTracker.getPlaylistSnapshot(url: playlistUrl, isForPlayback: false),
              playlist.hasIndependentSegments, !playlist.segments.isEmpty else {
            return position
        }

        return Self.adjustedSeekPosition(
            position,
            in: playlist,
            startOffset: startOffset(of: playlist),
            seekParameters: seekParameters
        )
    }

    // MARK: - I-frames

    /// The I-frame variants scrubbing may load, best first: from the one whose height is closest to the selected
    /// variant's down, so the keyframe looks no better than the video that plays.
    private var scrubbingIFrameVariants: [HlsMultivariantPlaylist.Variant] {
        let variants = iFrameVariants
            .filter { !failedIFramePlaylistUrls.contains($0.url) }
            .sorted { ($0.format.bitrate ?? 0) > ($1.format.bitrate ?? 0) }
        let height = Self.height(of: playlistFormats[selectedTrackIndex])
        let closest = variants.indices.min {
            abs(Self.height(of: variants[$0].format) - height) < abs(Self.height(of: variants[$1].format) - height)
        }
        guard height > 0, let closest else { return variants }
        return Array(variants[closest...])
    }

    /// The I-frame variant scrubbing starts with: the best whose keyframes, about a target duration of the selected
    /// variant apart, load quickly, else the smallest. The best while
    /// nothing tells how long they take.
    private func initialScrubbingIFrameVariant() -> HlsMultivariantPlaylist.Variant? {
        let variants = scrubbingIFrameVariants
        guard let trackSelection, let playlist = selectedPlaylistSnapshot,
              playlist.targetDuration.isNumeric, playlist.targetDuration > .zero else {
            return variants.first
        }
        // An I-frame variant's bandwidth is the size of a keyframe over the time to the next one.
        let interval = playlist.targetDuration.seconds
        return variants.first {
            trackSelection.loadsQuickly(bits: Double($0.format.bitrate ?? 0) * interval) != false
        } ?? variants.last
    }

    /// Loads the I-frame playlist scrubbing would start with, once a couple of chunks are buffered: the first scrubbing
    /// seek then only waits for its keyframe. Only for playlists that don't change, which it loads once.
    private func preloadScrubbingIFramePlaylist() {
        guard !isScrubbing, selectedPlaylistSnapshot?.hasEndTag == true,
              let url = initialScrubbingIFrameVariant()?.url, !preloadedIFramePlaylistUrls.contains(url) else {
            return
        }
        preloadedIFramePlaylistUrls.insert(url)
        SELogger.debug(.hls, "Loading I-frames of \(iFrameDescription(url)) ahead of scrubbing")
        playlistTracker.refreshPlaylist(url: url)
    }

    /// Moves scrubbing to the best I-frame playlist whose keyframe at the position loads quickly, or to
    /// the smallest. It moves down as soon as the keyframe takes too long, and up one
    /// playlist at a time with a margin, so seeks don't alternate between playlists as the bandwidth varies. A
    /// playlist not loaded yet is asked for, and taken once it is.
    private func adaptScrubbingIFramePlaylist(loadPosition: CMTime) {
        let variants = scrubbingIFrameVariants
        guard let currentUrl = scrubbingIFrameUrl,
              let current = variants.firstIndex(where: { $0.url == currentUrl }) else {
            // The playlist failed to load, or the selected variant changed: start over from the best.
            deactivateScrubbingIFramePlaylists()
            scrubbingIFrameUrl = initialScrubbingIFrameVariant()?.url
            return
        }
        guard let trackSelection,
              let playlist = playlistTracker.getPlaylistSnapshot(url: currentUrl, isForPlayback: false),
              !playlist.segments.isEmpty else {
            return
        }

        // The keyframe at the position, and alike ones of the other variants by their bandwidth.
        let index = Self.binarySearchFloor(
            playlist.segments,
            time: loadPosition - startOffset(of: playlist),
            stayInBounds: true
        )
        let segment = playlist.segments[index]
        let currentBitrate = Double(max(1, variants[current].format.bitrate ?? 0))
        let currentBits = segment.byteRangeLength.map { Double($0) * 8 } ?? currentBitrate * segment.duration.seconds
        func bits(_ index: Int) -> Double { currentBits * Double(variants[index].format.bitrate ?? 0) / currentBitrate }

        var target = current
        if trackSelection.loadsQuickly(bits: bits(current)) == false {
            target = (current + 1 ..< variants.count).first {
                trackSelection.loadsQuickly(bits: bits($0)) != false
            } ?? variants.count - 1
        } else if current > 0,
                  trackSelection.loadsQuickly(bits: bits(current - 1) * Self.iFrameSwitchUpMargin) == true {
            target = current - 1
        }

        let targetUrl = variants[target].url
        guard targetUrl != currentUrl else {
            if let pending = pendingScrubbingIFrameUrl { playlistTracker.deactivatePlaylistForPlayback(url: pending) }
            pendingScrubbingIFrameUrl = nil
            return
        }
        if playlistTracker.isSnapshotValid(url: targetUrl),
           playlistTracker.getPlaylistSnapshot(url: targetUrl, isForPlayback: true) != nil {
            let direction = target > current ? "down" : "up"
            SELogger.info(
                .hls,
                "Scrubbing switches \(direction) from I-frames of \(iFrameDescription(currentUrl)) "
                    + "to \(iFrameDescription(targetUrl))"
            )
            playlistTracker.deactivatePlaylistForPlayback(url: currentUrl)
            scrubbingIFrameUrl = targetUrl
            pendingScrubbingIFrameUrl = nil
        } else if pendingScrubbingIFrameUrl != targetUrl {
            if let pending = pendingScrubbingIFrameUrl { playlistTracker.deactivatePlaylistForPlayback(url: pending) }
            // Loads meanwhile; scrubbing keeps the playlist it has until then.
            pendingScrubbingIFrameUrl = targetUrl
            _ = playlistTracker.getPlaylistSnapshot(url: targetUrl, isForPlayback: true)
        }
    }

    /// The keyframe at the load position, from the I-frame playlist; nothing while chunks are queued.
    private func nextIFrameChunk(playlistUrl: URL, loadPosition: CMTime, queue: [HlsMediaChunk]) -> ChunkHolder {
        var holder = ChunkHolder()
        guard playlistTracker.isSnapshotValid(url: playlistUrl),
              let playlist = playlistTracker.getPlaylistSnapshot(url: playlistUrl, isForPlayback: true),
              !playlist.segments.isEmpty else {
            setExpectedPlaylistUrl(playlistUrl)
            holder.playlistUrl = playlistUrl
            return holder
        }
        setExpectedPlaylistUrl(nil)

        // A keyframe, or the buffer a seek landed in, shows the position: nothing more loads until a seek starts
        // loading over.
        if !queue.isEmpty {
            return holder
        }

        let startOffset = self.startOffset(of: playlist)
        let index = Self.binarySearchFloor(playlist.segments, time: loadPosition - startOffset, stayInBounds: true)
        let mediaSequence = playlist.mediaSequence + index
        let segment = playlist.segments[index]
        let initSegment = segment.initializationSegment
        let trackIndex = selectedTrackIndex

        let keyChunk = makeKeyChunkIfNeeded(
            initializationSegment: initSegment,
            encryption: segment.encryption,
            trackIndex: trackIndex
        )
        if let keyChunk {
            holder.chunk = keyChunk
            return holder
        }

        let discontinuitySequence = playlist.discontinuitySequence + segment.relativeDiscontinuitySequence
        let startTime = startOffset + segment.relativeStartTime
        let byteRange = "\(segment.byteRangeOffset)+\(segment.byteRangeLength.map(String.init) ?? "all")"
        SELogger.debug(
            .hls,
            "I-frame chunk \(mediaSequence) at \(startTime.seconds)s for a load at \(loadPosition.seconds)s: "
                + "\(segment.url.lastPathComponent) bytes \(byteRange)"
        )
        holder.chunk = HlsMediaChunk(
            uid: Self.nextChunkUid(),
            dataSpec: Self.makeDataSpec(
                url: segment.url,
                offset: segment.byteRangeOffset,
                length: segment.byteRangeLength,
                flags: .keepLoadedBytes
            ),
            // The selected variant's format: the keyframe stands for it.
            format: selectedFormat(ofTrack: trackIndex),
            trackSelectionReason: trackSelection?.selectedReason ?? .initial,
            trackSelectionData: trackSelection?.selectionData,
            startTime: startTime,
            endTime: startTime + segment.duration,
            mediaSequence: mediaSequence,
            discontinuitySequence: discontinuitySequence,
            playlistUrl: playlistUrl,
            initDataSpec: initSegment.map(Self.makeDataSpec(initializationSegment:))
                ?? Self.transportStreamHeader(of: segment, in: playlist),
            mediaKey: segmentKey(segment.encryption, mediaSequence: mediaSequence),
            initKey: segmentKey(initSegment?.encryption, mediaSequence: mediaSequence),
            isMasterTimestampSource: isTimestampMaster,
            timestampAdjuster: timestampAdjusterProvider.adjuster(discontinuitySequence: discontinuitySequence),
            previousChunk: nil,
            loaderQueue: loaderQueue,
            dataSourceFactory: dataSourceFactory,
            decryptionMemoryPool: decryptionMemoryPool,
            extractorFactory: extractorFactory,
            transferListener: transferListener,
            closedCaptionFormats: closedCaptionFormats,
            isIFrameOnly: true
        )
        return holder
    }

    // MARK: - Private

    /// The segments from `loadPosition` on of each track of the selection, by index in the selection: empty for a
    /// track whose playlist isn't loaded.
    private func makeMediaChunkIterators(loadPosition: CMTime) -> [MediaChunkIterator] {
        guard let trackSelection else { return [] }
        return (0 ..< trackSelection.length).map { selectionIndex -> MediaChunkIterator in
            guard let trackIndex = trackSelection.indexInTrackGroup(selectionIndex),
                  playlistUrls.indices.contains(trackIndex) else {
                return EmptyMediaChunkIterator()
            }
            let playlist = playlistTracker.getPlaylistSnapshot(url: playlistUrls[trackIndex], isForPlayback: false)
            guard let playlist, !playlist.segments.isEmpty else {
                return EmptyMediaChunkIterator()
            }

            let startOffset = self.startOffset(of: playlist)
            let first = Self.binarySearchFloor(playlist.segments, time: loadPosition - startOffset, stayInBounds: true)
            let chunks = playlist.segments[first...].prefix(Self.maxIteratedSegments).map { segment in
                HlsSegmentIterator.Chunk(
                    startTime: startOffset + segment.relativeStartTime,
                    endTime: startOffset + segment.endTime,
                    dataSpec: Self.makeDataSpec(
                        url: segment.url,
                        offset: segment.byteRangeOffset,
                        length: segment.byteRangeLength
                    )
                )
            }
            return HlsSegmentIterator(chunks: chunks)
        }
    }

    /// Whether a switch away from the old track must wait: the new track's next chunk left the live window, or starts
    /// before what the renderers already read, where its samples can't go in.
    private func shouldKeepCurrentTrack(
        oldTrackIndex: Int,
        playlist: HlsMediaPlaylist,
        position: SegmentPosition?,
        startOffset: CMTime,
        largestReadPosition: CMTime
    ) -> Bool {
        if let trackSelection, let selectionIndex = trackSelection.indexOf(indexInTrackGroup: oldTrackIndex),
           trackSelection.isTrackExcluded(index: selectionIndex, now: CMClock.hostTimeClock.time) {
            return false
        }
        guard let position else { return false }
        if position.mediaSequence < playlist.mediaSequence { return true }
        guard let segment = SegmentReference(position, in: playlist), largestReadPosition.isNumeric else {
            return false
        }
        return startOffset + segment.relativeStartTime < largestReadPosition
    }

    private func deactivatePlaylistForSelectedTrack(of selection: SETrackSelection?) {
        guard let selection else { return }
        guard let index = selection.selectedIndexInTrackGroup, playlistUrls.indices.contains(index) else {
            return
        }
        playlistTracker.deactivatePlaylistForPlayback(url: playlistUrls[index])
    }

    private func setExpectedPlaylistUrl(_ url: URL?) {
        if url != expectedPlaylistUrl {
            seenExpectedPlaylistError = false
        }
        expectedPlaylistUrl = url
    }

    /// Where the next chunk loads from, or `nil` if the playlist ends well before the position: it is older than
    /// playback, as the snapshot of a variant that didn't play for a while, and a newer one has to come first.
    private func nextPosition(
        previous: HlsMediaChunk?,
        switchingTrack: Bool,
        playlist: HlsMediaPlaylist,
        startOffset: CMTime,
        loadPosition: CMTime
    ) -> SegmentPosition? {
        if let previous, !switchingTrack, let mediaSequence = previous.chunkIndex {
            guard previous.isLoadCompleted else {
                return SegmentPosition(mediaSequence: mediaSequence, partIndex: previous.partIndex)
            }
            guard let partIndex = previous.partIndex else {
                return SegmentPosition(mediaSequence: mediaSequence + 1, partIndex: nil)
            }
            // The next part of the segment, until the segment is complete and the playlist lists no more of its parts.
            let isSegmentComplete = mediaSequence < playlist.endMediaSequence
            if isSegmentComplete, partIndex + 1 >= playlist.parts(ofMediaSequence: mediaSequence).count {
                return SegmentPosition(mediaSequence: mediaSequence + 1, partIndex: nil)
            }
            return SegmentPosition(mediaSequence: mediaSequence, partIndex: partIndex + 1)
        }

        // After a switch the new rendition starts where the previous chunk started, unless the segments are
        // independent and it can start where it ended.
        let targetPosition = previous.map { independentSegments ? $0.endTime : $0.startTime } ?? loadPosition
        let targetPositionInPlaylist = targetPosition - startOffset
        if !playlist.hasEndTag, targetPositionInPlaylist >= playlist.duration {
            // Right at the end, what comes next is the next part, or the next segment. Further past it, the
            // playlist's last part isn't what follows the position.
            let tolerance = playlist.isLowLatency ? playlist.partTargetDuration : playlist.targetDuration
            guard targetPositionInPlaylist - playlist.duration <= tolerance else {
                return nil
            }
            let availableParts = playlist.trailingParts.filter { !$0.isPreload }.count
            return SegmentPosition(
                mediaSequence: playlist.endMediaSequence,
                partIndex: playlist.isLowLatency ? availableParts : nil
            )
        }

        let index = Self.binarySearchFloor(
            playlist.segments,
            time: targetPositionInPlaylist,
            stayInBounds: !playlistTracker.isLive || previous == nil
        )
        let segmentPosition = SegmentPosition(mediaSequence: index + playlist.mediaSequence, partIndex: nil)
        guard playlist.isLowLatency else { return segmentPosition }

        // Close to the live edge the position may be in a segment that isn't complete, or in one that is but whose
        // parts load sooner: the part that starts with a keyframe at or before the position is where loading starts.
        let isInSegments = playlist.segments.indices.contains(index)
            && targetPositionInPlaylist < playlist.segments[index].endTime
        let mediaSequence = isInSegments ? segmentPosition.mediaSequence : playlist.endMediaSequence
        let parts = playlist.parts(ofMediaSequence: mediaSequence)
        let independentPart = parts.lastIndex {
            $0.isIndependent && !$0.isPreload && $0.relativeStartTime <= targetPositionInPlaylist
        }
        guard let independentPart else { return segmentPosition }
        return SegmentPosition(mediaSequence: mediaSequence, partIndex: independentPart)
    }

    private func makeKeyChunk(keyUrl: URL, trackIndex: Int) -> HlsEncryptionKeyChunk {
        SELogger.debug(.decryption, "Loading the key \(keyUrl.lastPathComponent) for variant \(trackIndex)")
        return HlsEncryptionKeyChunk(
            dataSpec: DataSpec.Builder(url: keyUrl).build(),
            trackFormat: playlistFormats[trackIndex],
            trackSelectionReason: trackSelection?.selectedReason ?? .initial,
            trackSelectionData: trackSelection?.selectionData,
            dataSourceFactory: dataSourceFactory
        )
    }

    /// The chunk that loads a key the segment or its initialization section needs and the source doesn't have yet.
    private func makeKeyChunkIfNeeded(
        initializationSegment: HlsMediaPlaylist.InitializationSegment?,
        encryption: HlsMediaPlaylist.SegmentEncryption?,
        trackIndex: Int
    ) -> HlsEncryptionKeyChunk? {
        let keyUrls = [initializationSegment?.encryption?.keyUrl, encryption?.keyUrl].compactMap { $0 }
        guard let keyUrl = keyUrls.first(where: { keyCache[$0] == nil }) else {
            return nil
        }
        return makeKeyChunk(keyUrl: keyUrl, trackIndex: trackIndex)
    }

    /// The loaded key and the initialization vector of a segment of the media sequence, if it is encrypted.
    private func segmentKey(_ encryption: HlsMediaPlaylist.SegmentEncryption?, mediaSequence: Int) -> HlsSegmentKey? {
        guard let encryption, let key = keyCache[encryption.keyUrl] else {
            return nil
        }
        return HlsSegmentKey(key: key, iv: encryption.iv(forMediaSequence: mediaSequence))
    }

    private func startScrubbing() {
        // Loaded ahead, so the first scrubbing seek can land on its keyframes.
        scrubbingIFrameUrl = initialScrubbingIFrameVariant()?.url
        guard let scrubbingIFrameUrl else {
            SELogger.info(.hls, "Scrubbing starts, without I-frames")
            return
        }
        _ = playlistTracker.getPlaylistSnapshot(url: scrubbingIFrameUrl, isForPlayback: true)
        SELogger.info(.hls, "Scrubbing starts, with I-frames of \(iFrameDescription(scrubbingIFrameUrl))")
    }

    private func stopScrubbing() {
        deactivateScrubbingIFramePlaylists()
        scrubbingIFrameUrl = nil
        SELogger.info(.hls, "Scrubbing ends")
    }

    /// Stops the I-frame playlists of scrubbing from reloading.
    private func deactivateScrubbingIFramePlaylists() {
        for url in [scrubbingIFrameUrl, pendingScrubbingIFrameUrl].compactMap({ $0 }) {
            playlistTracker.deactivatePlaylistForPlayback(url: url)
        }
        pendingScrubbingIFrameUrl = nil
    }

    // MARK: - Helpers

    private var selectedTrackIndex: Int {
        let index = trackSelection?.selectedIndexInTrackGroup ?? 0
        return playlistUrls.indices.contains(index) ? index : 0
    }

    private var selectedPlaylistSnapshot: HlsMediaPlaylist? {
        playlistTracker.getPlaylistSnapshot(url: playlistUrls[selectedTrackIndex], isForPlayback: false)
    }

    /// Where the playlist starts in the period: its times are relative to the start of the first primary playlist.
    private func startOffset(of playlist: HlsMediaPlaylist) -> CMTime {
        playlist.startTime - playlistTracker.initialStartTime
    }

    /// The selection's format of the track: the selection recognizes it in the queue of loaded chunks.
    private func selectedFormat(ofTrack trackIndex: Int) -> AnyFormat {
        trackSelection.map { $0.trackGroup.getFormat(index: trackIndex) } ?? playlistFormats[trackIndex]
    }

    private func iFrameDescription(_ url: URL) -> String {
        guard let format = iFrameVariants.first(where: { $0.url == url })?.format else {
            return url.lastPathComponent
        }
        return "\(Self.height(of: format))p at \((format.bitrate ?? 0) / 1000) kbit/s"
    }

    /// The height of the video of a variant, or 0 when the playlist doesn't tell.
    private static func height(of format: AnyFormat) -> Int {
        format.video?.size?.height ?? 0
    }

    private func logChunk(
        _ segment: SegmentReference,
        trackIndex: Int,
        oldTrackIndex: Int?,
        startTime: CMTime,
        discontinuitySequence: Int,
        isEncrypted: Bool
    ) {
        var attributes = ""
        if segment.isPreload { attributes += " (preload)" }
        if segment.hasGapTag { attributes += " (gap)" }
        var details = "discontinuity \(discontinuitySequence)"
        if isEncrypted { details += ", encrypted" }
        if let oldTrackIndex { details += ", switched from variant \(oldTrackIndex)" }
        SELogger.info(
            .hls,
            "Chunk \(segment.position)\(attributes) of variant \(trackIndex), "
                + "\(startTime.seconds)–\((startTime + segment.duration).seconds)s, \(details): "
                + segment.url.lastPathComponent
        )
    }
}

private extension HlsChunkSource {
    /// How much sooner than the startup delay a better I-frame playlist must load its keyframe to switch up to it.
    static let iFrameSwitchUpMargin = 1.5
    /// How many packets from the start of an MPEG-TS file hold the tables that tell its streams.
    static let transportStreamHeaderPackets = 8
    static let transportStreamPacketSize = 188
    /// How many segments ahead the selection gets to plan with.
    static let maxIteratedSegments = 32

    static let uidLock = UnfairLock()
    nonisolated(unsafe) static var lastChunkUid = 0

    static func nextChunkUid() -> Int {
        uidLock.withLock {
            lastChunkUid += 1
            return lastChunkUid
        }
    }

    static func makeDataSpec(url: URL, offset: Int, length: Int?, flags: DataSpec.Flags = []) -> DataSpec {
        DataSpec.Builder(url: url)
            .setPosition(offset)
            .setLength(length)
            .setFlags(flags)
            .build()
    }

    static func makeDataSpec(initializationSegment: HlsMediaPlaylist.InitializationSegment) -> DataSpec {
        makeDataSpec(
            url: initializationSegment.url,
            offset: initializationSegment.byteRangeOffset,
            length: initializationSegment.byteRangeLength,
            flags: .keepLoadedBytes
        )
    }

    /// The start of the file of a keyframe of an I-frame playlist without initialization sections, as in MPEG-TS: the
    /// tables that tell the streams of the file, which the keyframe's byte range leaves out. It ends where the file's
    /// first keyframe starts; `nil` when the keyframe's range starts the file.
    static func transportStreamHeader(of segment: HlsMediaPlaylist.Segment, in playlist: HlsMediaPlaylist) -> DataSpec? {
        guard segment.byteRangeOffset > 0 else { return nil }
        let firstKeyframeOffset = playlist.segments.lazy
            .filter { $0.url == segment.url }
            .map(\.byteRangeOffset)
            .min() ?? segment.byteRangeOffset
        let length = min(firstKeyframeOffset, transportStreamHeaderPackets * transportStreamPacketSize)
        guard length > 0 else { return nil }
        return makeDataSpec(url: segment.url, offset: 0, length: length, flags: .keepLoadedBytes)
    }

    /// The segment start near the position that the seek parameters allow, for segments that start with a sync sample.
    static func adjustedSeekPosition(
        _ position: CMTime,
        in playlist: HlsMediaPlaylist,
        startOffset: CMTime,
        seekParameters: SeekParameters
    ) -> CMTime {
        let index = binarySearchFloor(playlist.segments, time: position - startOffset, stayInBounds: true)
        let firstSync = startOffset + playlist.segments[index].relativeStartTime
        let secondSync = index + 1 < playlist.segments.count
            ? startOffset + playlist.segments[index + 1].relativeStartTime
            : firstSync
        return seekParameters.resolveSyncPosition(position: position, firstSync: firstSync, secondSync: secondSync)
    }

    /// The index of the last segment that starts at or before the time.
    ///
    /// - Parameter stayInBounds: Whether a time before the first segment gives the first segment, not -1.
    static func binarySearchFloor(_ segments: [HlsMediaPlaylist.Segment], time: CMTime, stayInBounds: Bool) -> Int {
        var low = 0
        var high = segments.count - 1
        var result = -1
        while low <= high {
            let middle = (low + high) / 2
            if segments[middle].relativeStartTime <= time {
                result = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return stayInBounds ? max(0, result) : result
    }
}

/// Where in a media playlist a chunk loads: a segment, or a part of it.
struct SegmentPosition: CustomStringConvertible {
    /// The media sequence number of the segment.
    let mediaSequence: Int
    /// The index of the part in the segment, or `nil` for the whole segment.
    let partIndex: Int?

    var description: String {
        partIndex.map { "\(mediaSequence).\($0)" } ?? "\(mediaSequence)"
    }
}

/// A segment or a part of a media playlist, with what loading it needs.
private struct SegmentReference {
    /// Where the segment or part is: a segment being made resolves to its first part.
    let position: SegmentPosition
    let url: URL
    let initializationSegment: HlsMediaPlaylist.InitializationSegment?
    let duration: CMTime
    let relativeStartTime: CMTime
    let relativeDiscontinuitySequence: Int
    let encryption: HlsMediaPlaylist.SegmentEncryption?
    let byteRangeOffset: Int
    let byteRangeLength: Int?
    /// Whether the part is the one a preload hint announces.
    let isPreload: Bool
    /// Whether the segment or part is marked as a gap: there is nothing to load.
    let hasGapTag: Bool
    /// Whether the part says it starts with a keyframe; `nil` for a whole segment.
    let isIndependentPart: Bool?

    /// Whether the segment or part starts with a keyframe: a part that says so, a first part, or a segment, when the
    /// playlist's segments are independent.
    func isIndependent(in playlist: HlsMediaPlaylist) -> Bool {
        if let isIndependentPart {
            return isIndependentPart || (position.partIndex == 0 && playlist.hasIndependentSegments)
        }
        return playlist.hasIndependentSegments
    }

    /// The segment or part at the position, or `nil` if the playlist doesn't have it yet.
    init?(_ position: SegmentPosition, in playlist: HlsMediaPlaylist) {
        let segmentIndex = position.mediaSequence - playlist.mediaSequence
        if let partIndex = position.partIndex {
            let parts = playlist.parts(ofMediaSequence: position.mediaSequence)
            guard parts.indices.contains(partIndex) else { return nil }
            let part = parts[partIndex]
            self.init(
                position: position,
                url: part.url,
                initializationSegment: part.initializationSegment,
                duration: part.duration,
                relativeStartTime: part.relativeStartTime,
                relativeDiscontinuitySequence: part.relativeDiscontinuitySequence,
                encryption: part.encryption,
                byteRangeOffset: part.byteRangeOffset,
                byteRangeLength: part.byteRangeLength,
                isPreload: part.isPreload,
                hasGapTag: part.hasGapTag,
                isIndependentPart: part.isIndependent
            )
        } else if playlist.segments.indices.contains(segmentIndex) {
            let segment = playlist.segments[segmentIndex]
            self.init(
                position: position,
                url: segment.url,
                initializationSegment: segment.initializationSegment,
                duration: segment.duration,
                relativeStartTime: segment.relativeStartTime,
                relativeDiscontinuitySequence: segment.relativeDiscontinuitySequence,
                encryption: segment.encryption,
                byteRangeOffset: segment.byteRangeOffset,
                byteRangeLength: segment.byteRangeLength,
                isPreload: false,
                hasGapTag: segment.hasGapTag,
                isIndependentPart: nil
            )
        } else if segmentIndex == playlist.segments.count, playlist.isLowLatency, !playlist.trailingParts.isEmpty {
            // The segment being made loads by its parts, from the first.
            self.init(SegmentPosition(mediaSequence: position.mediaSequence, partIndex: 0), in: playlist)
        } else {
            return nil
        }
    }

    private init(
        position: SegmentPosition,
        url: URL,
        initializationSegment: HlsMediaPlaylist.InitializationSegment?,
        duration: CMTime,
        relativeStartTime: CMTime,
        relativeDiscontinuitySequence: Int,
        encryption: HlsMediaPlaylist.SegmentEncryption?,
        byteRangeOffset: Int,
        byteRangeLength: Int?,
        isPreload: Bool,
        hasGapTag: Bool,
        isIndependentPart: Bool?
    ) {
        self.position = position
        self.url = url
        self.initializationSegment = initializationSegment
        self.duration = duration
        self.relativeStartTime = relativeStartTime
        self.relativeDiscontinuitySequence = relativeDiscontinuitySequence
        self.encryption = encryption
        self.byteRangeOffset = byteRangeOffset
        self.byteRangeLength = byteRangeLength
        self.isPreload = isPreload
        self.hasGapTag = hasGapTag
        self.isIndependentPart = isIndependentPart
    }
}

/// Keys by url, keeping the few used last.
private struct KeyCache {
    let capacity: Int
    private var entries: [(url: URL, key: Data)] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    subscript(url: URL) -> Data? {
        entries.last { $0.url == url }?.key
    }

    mutating func insert(_ key: Data, for url: URL) {
        entries.removeAll { $0.url == url }
        entries.append((url, key))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}

/// Loads the key of AES-128 encrypted segments.
final class HlsEncryptionKeyChunk: Chunk, @unchecked Sendable {
    /// The loaded key, once the load completed.
    var key: Data? { lock.withLock { _key } }

    private let dataSourceFactory: DataSourceFactory
    private let lock = UnfairLock()
    private var _key: Data? // guarded by lock

    init(
        dataSpec: DataSpec,
        trackFormat: AnyFormat,
        trackSelectionReason: TrackSelectionReason,
        trackSelectionData: Any?,
        dataSourceFactory: DataSourceFactory
    ) {
        self.dataSourceFactory = dataSourceFactory
        super.init(
            dataSpec: dataSpec,
            dataType: .drm,
            trackFormat: trackFormat,
            trackSelectionReason: trackSelectionReason,
            trackSelectionData: trackSelectionData,
            startTime: .invalid,
            endTime: .invalid
        )
    }

    override func load(_ isolation: isolated any Actor) async throws {
        let loadable = ParsingLoadable<Data>(dataSpec: dataSpec, dataSourceFactory: dataSourceFactory) { buffer, _ in
            // The key is 16 bytes: copying it is cheaper than keeping its buffer.
            try buffer.dataBytes()
        }
        try await loadable.load(isolation)
        guard let key = loadable.result, key.count == 16 else {
            throw ParserError.createForMalformedManifest(message: "AES-128 key at \(dataSpec.url) is not 16 bytes.")
        }
        addBytesLoaded(key.count)
        lock.withLock { _key = key }
    }
}

/// The upcoming segments of a media playlist, as chunks.
final class HlsSegmentIterator: MediaChunkIterator {
    struct Chunk {
        let startTime: CMTime
        let endTime: CMTime
        let dataSpec: DataSpec
    }

    private let chunks: [Chunk]
    private var index = -1

    init(chunks: [Chunk]) {
        self.chunks = chunks
    }

    var isEnded: Bool { index >= chunks.count }
    var dataSpec: DataSpec? { current?.dataSpec }
    var chunkStartTimeUs: Int64? { current.map { Self.microseconds($0.startTime) } }
    var chunkEndTimeUs: Int64? { current.map { Self.microseconds($0.endTime) } }

    func next() throws -> Bool {
        index = min(index + 1, chunks.count)
        return !isEnded
    }

    func reset() {
        index = -1
    }

    private var current: Chunk? {
        chunks.indices.contains(index) ? chunks[index] : nil
    }

    private static func microseconds(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }
}
