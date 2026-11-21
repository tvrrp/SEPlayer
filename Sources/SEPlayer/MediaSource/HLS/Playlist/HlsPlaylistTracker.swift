//
//  HlsPlaylistTracker.swift
//  SEPlayer
//

import CoreMedia
import DataSource
import Foundation
import SEPlayerCommon

/// Tracks playlists associated with an HLS stream and provides snapshots.
///
/// The tracker loads the multivariant playlist, then the primary media playlist, and any other media playlist when
/// a snapshot of it is asked for. The primary playlist is the variant that plays: it follows the adaptive selection.
///
/// Playlists of a live stream are reloaded. The primary one reloads by itself, every target duration while it changes
/// and every half target duration while it doesn't; the others reload when a chunk source needs a segment they don't
/// list yet, or reload by themselves too while they play. A server that blocks reloads is asked at once for the next
/// segment, or the next part of a low-latency playlist, and answers when it has it; one that skips segments sends
/// only what changed. A playlist that stops changing for 3.5 target durations, or whose media sequence goes back,
/// fails.
///
/// Runs on the player queue.
final class HlsPlaylistTracker {
    /// Called on media playlist changes.
    protocol Listener: AnyObject {
        /// Called when a playlist changes.
        func onPlaylistChanged()
        /// Called if an error is encountered while loading a playlist.
        ///
        /// - Parameter forceRetry: Whether the playlist must load again rather than fall back to another track.
        /// - Returns: Whether the listener excluded the track of the playlist, or doesn't play it. The load retries
        ///   unless all listeners excluded it.
        func onPlaylistError(url: URL, errorInfo: LoadErrorInfo, forceRetry: Bool) -> Bool
    }

    /// Listener for primary playlist changes.
    protocol PrimaryPlaylistListener: AnyObject {
        /// Called when the primary playlist changes.
        func onPrimaryPlaylistRefreshed(_ playlist: HlsMediaPlaylist)
    }

    /// Thrown when a live playlist stops changing for too long.
    struct PlaylistStuckError: PlaybackErrorCodeProviding {
        let url: URL
        var errorCode: PlaybackErrorCode { .ioUnspecified }
    }

    /// Thrown when the media sequence of a live playlist goes back: the server probably restarted the stream.
    struct PlaylistResetError: PlaybackErrorCodeProviding {
        let url: URL
        var errorCode: PlaybackErrorCode { .ioUnspecified }
    }

    /// The listeners of playlist changes and errors. A listener adds itself.
    let listeners = MulticastDelegate<Listener>(isThreadSafe: false)

    /// The multivariant playlist, once loaded.
    private(set) var multivariantPlaylist: HlsMultivariantPlaylist?
    /// The start time of the first loaded primary playlist, which period times are relative to.
    private(set) var initialStartTime: CMTime = .invalid
    /// Whether the tracked stream can still change.
    private(set) var isLive = false

    private let queue: Queue
    private let loaderQueue: Queue
    private let dataSourceFactory: DataSourceFactory
    private let loadErrorHandlingPolicy: LoadErrorHandlingPolicy
    /// The bitrate playback will likely start with, in bits per second, or `nil` without an estimate.
    private let startBitrateEstimate: () -> Int?

    private weak var primaryPlaylistListener: PrimaryPlaylistListener?
    private var initialPlaylistUrl: URL?
    private var initialLoader: Loader?
    private var bundles: [URL: MediaPlaylistBundle] = [:]
    private var primaryMediaPlaylistUrl: URL?
    private var primaryMediaPlaylistSnapshot: HlsMediaPlaylist?
    private var initialLoadError: Error?

    init(
        queue: Queue,
        loaderQueue: Queue,
        dataSourceFactory: DataSourceFactory,
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy(),
        startBitrateEstimate: @escaping () -> Int? = { nil }
    ) {
        self.queue = queue
        self.loaderQueue = loaderQueue
        self.dataSourceFactory = dataSourceFactory
        self.loadErrorHandlingPolicy = loadErrorHandlingPolicy
        self.startBitrateEstimate = startBitrateEstimate
    }

    /// Starts the playlist tracker.
    func start(initialPlaylistUrl: URL, primaryPlaylistListener: PrimaryPlaylistListener) {
        assert(queue.isCurrent())
        self.initialPlaylistUrl = initialPlaylistUrl
        self.primaryPlaylistListener = primaryPlaylistListener

        SELogger.info(.playlist, "Loading \(initialPlaylistUrl.lastPathComponent)")
        // The playlists and segments after this one come several at once: a second connection opened now is ready
        // for them, rather than handshaking while they wait.
        dataSourceFactory.preconnect(to: initialPlaylistUrl)
        let loader = Loader(workQueue: queue, loadQueue: loaderQueue)
        initialLoader = loader
        loader.startLoading(
            loadable: makeLoadable(url: initialPlaylistUrl, multivariantPlaylist: nil),
            callback: self,
            defaultMinRetryCount: minRetryCount
        )
    }

    /// Stops the playlist tracker and releases any acquired resources.
    func stop() {
        assert(queue.isCurrent())
        primaryMediaPlaylistUrl = nil
        primaryMediaPlaylistSnapshot = nil
        multivariantPlaylist = nil
        initialStartTime = .invalid
        isLive = false
        initialLoader?.release()
        initialLoader = nil
        bundles.values.forEach { $0.release() }
        bundles.removeAll()
        initialLoadError = nil
    }

    /// Returns the most recent snapshot available of the playlist, or `nil` if none was loaded yet.
    ///
    /// - Parameter isForPlayback: Whether the playlist is about to be played. A playlist that isn't loaded yet
    ///   starts loading, and a variant becomes the primary playlist.
    func getPlaylistSnapshot(url: URL, isForPlayback: Bool) -> HlsMediaPlaylist? {
        assert(queue.isCurrent())
        let snapshot = bundles[url]?.playlistSnapshot
        if isForPlayback {
            if snapshot == nil {
                bundles[url]?.loadPlaylist()
            } else {
                maybeSetPrimaryUrl(url)
            }
            maybeActivateForPlayback(url)
        }
        return snapshot
    }

    /// Stops reloading a playlist that no longer plays, unless it is the primary one.
    func deactivatePlaylistForPlayback(url: URL) {
        assert(queue.isCurrent())
        bundles[url]?.isActiveForPlayback = false
    }

    /// Whether the snapshot of the playlist is enough to play from: one of a stream that only grows or doesn't change,
    /// or a recent one, loaded within the duration of the playlist and at least 30 seconds.
    func isSnapshotValid(url: URL) -> Bool {
        assert(queue.isCurrent())
        return bundles[url]?.isSnapshotValid ?? false
    }

    /// If the tracker failed to load the multivariant or the primary playlist, throws the error.
    func maybeThrowPrimaryPlaylistRefreshError() throws {
        assert(queue.isCurrent())
        try initialLoader?.maybeThrowError(minRetryCount: minRetryCount)
        if let initialLoadError { throw initialLoadError }
        if let primaryMediaPlaylistUrl {
            try maybeThrowPlaylistRefreshError(url: primaryMediaPlaylistUrl)
        }
    }

    /// If the playlist failed to load, throws the error.
    func maybeThrowPlaylistRefreshError(url: URL) throws {
        assert(queue.isCurrent())
        try bundles[url]?.maybeThrowError()
    }

    /// Loads the playlist again, if it can change, as soon as a reload is allowed.
    func refreshPlaylist(url: URL) {
        assert(queue.isCurrent())
        bundles[url]?.loadPlaylist()
    }

    /// Excludes a media playlist that failed to load. An excluded primary playlist gives way to another variant.
    ///
    /// - Returns: Whether the playlist was excluded: it isn't the primary playlist, or another variant took over.
    func excludeMediaPlaylist(url: URL, exclusionDuration: CMTime) -> Bool {
        assert(queue.isCurrent())
        guard let bundle = bundles[url] else { return false }
        bundle.exclude(for: exclusionDuration)
        return !isPrimary(url) || maybeSelectNewPrimaryUrl()
    }

    fileprivate var minRetryCount: Int {
        loadErrorHandlingPolicy.getMinimumLoadableRetryCount(dataType: .manifest)
    }
}

// MARK: - Loading

private extension HlsPlaylistTracker {
    typealias PlaylistLoadable = ParsingLoadable<HlsParsedPlaylist>

    /// - Parameters:
    ///   - previousMediaPlaylist: The snapshot a delta update of the playlist updates.
    ///   - isBlockingReload: Whether the server holds the response until the playlist changes: the load doesn't
    ///     measure the network.
    func makeLoadable(
        url: URL,
        multivariantPlaylist: HlsMultivariantPlaylist?,
        previousMediaPlaylist: HlsMediaPlaylist? = nil,
        isBlockingReload: Bool = false
    ) -> PlaylistLoadable {
        PlaylistLoadable(
            dataSpec: DataSpec.Builder(url: url)
                .setFlags(isBlockingReload ? .mightNotUseFullNetworkSpeed : [])
                .build(),
            dataSourceFactory: dataSourceFactory,
            parser: { buffer, url in
                let parser = HlsPlaylistParser(
                    multivariantPlaylist: multivariantPlaylist,
                    previousMediaPlaylist: previousMediaPlaylist
                )
                return try parser.parse(buffer: buffer, url: url)
            }
        )
    }

    func createBundles(for urls: [URL]) {
        for url in urls where bundles[url] == nil {
            bundles[url] = MediaPlaylistBundle(tracker: self, url: url)
        }
    }

    /// Makes the variant the primary playlist, unless the stream ended. A snapshot that may be stale is reloaded
    /// before it is reported.
    func maybeSetPrimaryUrl(_ url: URL) {
        guard url != primaryMediaPlaylistUrl,
              multivariantPlaylist?.variants.contains(where: { $0.url == url }) == true,
              primaryMediaPlaylistSnapshot?.hasEndTag != true,
              let bundle = bundles[url] else {
            return
        }

        primaryMediaPlaylistUrl = url
        if let snapshot = bundle.playlistSnapshot, snapshot.hasEndTag {
            primaryMediaPlaylistSnapshot = snapshot
            primaryPlaylistListener?.onPrimaryPlaylistRefreshed(snapshot)
        } else {
            bundle.loadPlaylist(requestUrl: requestUrlForPrimaryChange(to: url))
        }
    }

    /// The first request of a variant that becomes the primary playlist: from the report of the old primary playlist,
    /// a blocking request for the variant's last segment and part, which the server answers as soon as it can.
    func requestUrlForPrimaryChange(to url: URL) -> URL? {
        guard let primary = primaryMediaPlaylistSnapshot, primary.serverControl.canBlockReload,
              let report = primary.renditionReport(for: url) else {
            return nil
        }
        return MediaPlaylistBundle.blockingRequestUrl(
            for: url,
            mediaSequence: report.lastMediaSequence,
            partIndex: report.lastPartIndex
        )
    }

    /// Keeps a playlist that plays reloading by itself, as the primary one does: a rendition of a live low-latency
    /// stream can't wait to be asked for each of its parts.
    func maybeActivateForPlayback(_ url: URL) {
        guard let bundle = bundles[url], !bundle.isActiveForPlayback else {
            return
        }
        bundle.isActiveForPlayback = true
        if let snapshot = bundle.playlistSnapshot, !snapshot.hasEndTag {
            bundle.loadPlaylist()
        }
    }

    func isPrimary(_ url: URL) -> Bool {
        url == primaryMediaPlaylistUrl
    }

    func onPlaylistUpdated(url: URL, playlist: HlsMediaPlaylist) {
        if url == primaryMediaPlaylistUrl {
            if primaryMediaPlaylistSnapshot == nil {
                // The first primary playlist sets the time that period times are relative to.
                initialStartTime = playlist.startTime
                isLive = !playlist.hasEndTag
            }
            primaryMediaPlaylistSnapshot = playlist
            primaryPlaylistListener?.onPrimaryPlaylistRefreshed(playlist)
        }
        listeners.invokeDelegates { $0.onPlaylistChanged() }
    }

    /// Tells the listeners a playlist failed to load.
    ///
    /// - Returns: Whether a listener couldn't exclude the track of the playlist: the playlist has to load again.
    @discardableResult
    func notifyPlaylistError(url: URL, errorInfo: LoadErrorInfo, forceRetry: Bool) -> Bool {
        var anyExclusionFailed = false
        if primaryMediaPlaylistSnapshot == nil {
            // Nobody plays a variant yet: the tracker can still pick another one to start with.
            maybeExcludeFirstPrimaryPlaylist(url: url, errorInfo: errorInfo)
            anyExclusionFailed = true
        }
        listeners.invokeDelegates {
            anyExclusionFailed = !$0.onPlaylistError(url: url, errorInfo: errorInfo, forceRetry: forceRetry)
                || anyExclusionFailed
        }
        return anyExclusionFailed
    }

    /// Excludes a variant that fails before the first primary playlist loaded, if another can be the primary one.
    private func maybeExcludeFirstPrimaryPlaylist(url: URL, errorInfo: LoadErrorInfo) {
        guard let variants = multivariantPlaylist?.variants else { return }
        let now = CMClock.hostTimeClock.time
        let excludedCount = variants.filter { bundles[$0.url]?.isExcluded(at: now) == true }.count
        let fallbackOptions = FallbackOptions(
            numberOfLocations: 1,
            numberOfExcludedLocations: 0,
            numberOfTracks: variants.count,
            numberOfExcludedTracks: excludedCount
        )
        let fallback = loadErrorHandlingPolicy.getFallbackSelection(for: fallbackOptions, loadErrorInfo: errorInfo)
        guard let fallback, fallback.type == .track, bundles[url] != nil else { return }

        _ = excludeMediaPlaylist(url: url, exclusionDuration: fallback.exclusionDuration)
    }

    /// Makes the first variant that isn't excluded the primary playlist, when the primary one is.
    ///
    /// - Returns: Whether another variant became the primary playlist.
    private func maybeSelectNewPrimaryUrl() -> Bool {
        let now = CMClock.hostTimeClock.time
        for variant in multivariantPlaylist?.variants ?? [] where variant.url != primaryMediaPlaylistUrl {
            guard let bundle = bundles[variant.url], !bundle.isExcluded(at: now) else {
                continue
            }

            primaryMediaPlaylistUrl = variant.url
            bundle.loadPlaylist()
            return true
        }
        return false
    }

    // MARK: Snapshots

    /// The snapshot after a load: the loaded playlist if it is newer, with the start time and discontinuity sequence
    /// it doesn't declare carried over from the old snapshot; else the old snapshot.
    ///
    /// - Returns: The snapshot, and whether it differs from the old one.
    func latestPlaylistSnapshot(old: HlsMediaPlaylist?, loaded: HlsMediaPlaylist) -> (HlsMediaPlaylist, Bool) {
        guard loaded.isNewer(than: old) else {
            guard let old else { return (loaded, true) }
            // The same segments again, but the stream ended.
            if loaded.hasEndTag, !old.hasEndTag {
                return (old.copyWithEndTag(), true)
            }
            return (old, false)
        }
        let playlist = loaded.copyWith(
            startTime: loadedPlaylistStartTime(old: old, loaded: loaded),
            discontinuitySequence: loadedPlaylistDiscontinuitySequence(old: old, loaded: loaded)
        )
        return (playlist, true)
    }

    /// The start time of a loaded playlist: its program date time, or where its first segment was in the old
    /// snapshot, or the end of the old snapshot when it continues right after, or else the primary playlist's.
    func loadedPlaylistStartTime(old: HlsMediaPlaylist?, loaded: HlsMediaPlaylist) -> CMTime {
        if loaded.hasProgramDateTime { return loaded.startTime }
        let primarySnapshotStartTime = primaryMediaPlaylistSnapshot?.startTime ?? .zero
        guard let old else { return primarySnapshotStartTime }
        if let segment = firstOldOverlappingSegment(old: old, loaded: loaded) {
            return old.startTime + segment.relativeStartTime
        }
        if old.segments.count == loaded.mediaSequence - old.mediaSequence {
            return old.endTime
        }
        return primarySnapshotStartTime
    }

    /// The discontinuity sequence of a loaded playlist: the one it declares, or the one of its first segment in the
    /// old snapshot, or else the primary playlist's.
    func loadedPlaylistDiscontinuitySequence(old: HlsMediaPlaylist?, loaded: HlsMediaPlaylist) -> Int {
        if loaded.hasDiscontinuitySequence { return loaded.discontinuitySequence }
        let primaryDiscontinuitySequence = primaryMediaPlaylistSnapshot?.discontinuitySequence ?? 0
        guard let old,
              let segment = firstOldOverlappingSegment(old: old, loaded: loaded),
              let firstLoadedSegment = loaded.segments.first else {
            return primaryDiscontinuitySequence
        }

        return old.discontinuitySequence + segment.relativeDiscontinuitySequence
            - firstLoadedSegment.relativeDiscontinuitySequence
    }

    /// The segment of the old snapshot that is the first segment of the loaded playlist, if the old one lists it.
    func firstOldOverlappingSegment(old: HlsMediaPlaylist, loaded: HlsMediaPlaylist) -> HlsMediaPlaylist.Segment? {
        let mediaSequenceOffset = loaded.mediaSequence - old.mediaSequence
        guard mediaSequenceOffset >= 0, mediaSequenceOffset < old.segments.count else {
            return nil
        }
        return old.segments[mediaSequenceOffset]
    }
}

// MARK: - Loader.Callback (multivariant or initial media playlist)

extension HlsPlaylistTracker: Loader.Callback {
    func onLoadStarted(
        loadable: ParsingLoadable<HlsParsedPlaylist>,
        onTime: DispatchTime,
        loadDuration: DispatchTimeInterval,
        retryCount: Int
    ) {}

    func onLoadCompleted(
        loadable: ParsingLoadable<HlsParsedPlaylist>,
        onTime: DispatchTime,
        loadDuration: DispatchTimeInterval
    ) {
        guard let result = loadable.result else {
            initialLoadError = ParserError.createForMalformedManifest(message: "Playlist is empty.")
            return
        }

        switch result {
        case let .multivariant(playlist):
            SELogger.info(
                .playlist,
                "Multivariant playlist in \(loadDuration.totalMilliseconds)ms: \(playlist.variants.count) variants, "
                    + "\(playlist.iFrameVariants.count) I-frame variants"
            )
            multivariantPlaylist = playlist
            let startVariant = Self.likelyStartVariant(of: playlist.variants, bitrate: startBitrateEstimate())
            guard let primaryUrl = startVariant?.url else {
                initialLoadError = ParserError.createForMalformedManifest(
                    message: "Multivariant playlist has no variants."
                )
                return
            }
            primaryMediaPlaylistUrl = primaryUrl
            createBundles(for: playlist.mediaPlaylistUrls)
            bundles[primaryUrl]?.loadPlaylist()
        case let .media(playlist):
            // A media playlist on its own is the single variant of a multivariant playlist.
            let url = loadable.dataSpec.url
            SELogger.info(.playlist, "Media playlist without variants in \(loadDuration.totalMilliseconds)ms")
            multivariantPlaylist = .createSingleVariantMultivariantPlaylist(variantUrl: url)
            primaryMediaPlaylistUrl = url
            createBundles(for: [url])
            bundles[url]?.processLoadedPlaylist(playlist, loadDuration: loadDuration.time)
        }
    }

    func onLoadCancelled(
        loadable: ParsingLoadable<HlsParsedPlaylist>,
        onTime: DispatchTime,
        loadDuration: DispatchTimeInterval,
        released: Bool
    ) {}

    func onLoadError(
        loadable: ParsingLoadable<HlsParsedPlaylist>,
        onTime: DispatchTime,
        loadDuration: DispatchTimeInterval,
        error: Error,
        errorCount: Int
    ) -> Loader.LoadErrorAction {
        let name = loadable.dataSpec.url.lastPathComponent
        let errorInfo = LoadErrorInfo(dataType: .manifest, error: error, errorCount: errorCount)
        guard let retryDelay = loadErrorHandlingPolicy.getRetryDelay(for: errorInfo) else {
            SELogger.error(.playlist, "HLS playlist \(name) failed with a fatal error, not retrying: \(error)")
            return .dontRetryFatal
        }
        SELogger.warning(
            .playlist,
            "HLS playlist \(name) failed (attempt \(errorCount)), "
                + "retrying in \(retryDelay.totalMilliseconds)ms: \(error)"
        )
        return .createRetryAction(resetErrorCount: false, retryDelay: retryDelay)
    }
}

extension HlsPlaylistTracker {
    /// The variant playback likely starts with, whose playlist is loaded first as the primary one: the best that fits
    /// `bitrate`, else the lowest, as the track selection picks without measurements. Only variants of the first one's
    /// video codec count, the one the stream offers first. Without an estimate, the first variant.
    ///
    /// The primary playlist only tells the timeline: any variant would do, but one that playback doesn't take is a
    /// playlist loaded for nothing before the first segment.
    static func likelyStartVariant(
        of variants: [HlsMultivariantPlaylist.Variant],
        bitrate: Int?
    ) -> HlsMultivariantPlaylist.Variant? {
        guard let first = variants.first, let bitrate, bitrate > 0 else {
            return variants.first
        }
        let codec = VariantFilters.VideoFormat(codecs: first.format.codecs)
        let candidates = variants.filter {
            ($0.format.bitrate ?? 0) > 0 && VariantFilters.VideoFormat(codecs: $0.format.codecs) == codec
        }
        let fitting = candidates.filter { ($0.format.bitrate ?? 0) <= bitrate }
        return fitting.max { ($0.format.bitrate ?? 0) < ($1.format.bitrate ?? 0) }
            ?? candidates.min { ($0.format.bitrate ?? 0) < ($1.format.bitrate ?? 0) }
            ?? first
    }
}

// MARK: - Media playlist bundle

private extension HlsPlaylistTracker {
    /// Holds all information related to a specific media playlist.
    final class MediaPlaylistBundle: Loader.Callback {
        let url: URL
        /// Whether the playlist plays: it reloads by itself, as the primary one does.
        var isActiveForPlayback = false
        private(set) var playlistSnapshot: HlsMediaPlaylist?

        var isSnapshotValid: Bool {
            guard let playlistSnapshot else { return false }
            let neverLosesSegments = playlistSnapshot.playlistType == .event || playlistSnapshot.playlistType == .vod
            if playlistSnapshot.hasEndTag || neverLosesSegments {
                return true
            }
            let validity = max(Self.minSnapshotValidityDuration, playlistSnapshot.duration)
            return lastSnapshotLoadTime + validity > CMClock.hostTimeClock.time
        }

        private unowned let tracker: HlsPlaylistTracker
        private let loader: Loader
        /// Fires when a reload that had to wait is allowed.
        private let reloadTimer: DispatchSourceTimer
        private var loadError: Error?
        /// The error of a live playlist that stopped changing or went back.
        private var playlistError: Error?
        /// When the playlist may load again, on the host time clock.
        private var earliestNextLoadTime: CMTime = .zero
        private var lastSnapshotLoadTime: CMTime = .zero
        private var lastSnapshotChangeTime: CMTime = .zero
        private var isLoadPending = false
        /// The request of the load that waits: one that asks for something else than the next reload.
        private var pendingRequestUrl: URL?
        /// Whether the next reload may ask the server to block or to skip: not after it failed to.
        private var allowsDeliveryDirectives = true
        private var isReleased = false
        /// Until when the playlist is excluded after it failed to load, on the host time clock.
        private var excludeUntil: CMTime = .zero

        init(tracker: HlsPlaylistTracker, url: URL) {
            self.tracker = tracker
            self.url = url
            loader = Loader(workQueue: tracker.queue, loadQueue: tracker.loaderQueue)
            reloadTimer = DispatchSource.makeTimerSource(queue: tracker.queue.queue)
            reloadTimer.setEventHandler { [weak self] in
                guard let self, !isReleased else { return }
                isLoadPending = false
                let requestUrl = pendingRequestUrl
                pendingRequestUrl = nil
                loadPlaylistImmediately(requestUrl: requestUrl)
            }
            reloadTimer.activate()
        }

        deinit {
            reloadTimer.cancel()
        }

        /// Loads the playlist if it can change and isn't loading, once a reload is allowed.
        ///
        /// - Parameter requestUrl: What to request instead of the next reload, as a blocking request a rendition
        ///   report makes possible.
        func loadPlaylist(requestUrl: URL? = nil) {
            // A playlist that failed with a fatal error doesn't load again: its error stays for the player to throw.
            guard !isReleased, !isLoadPending, !loader.isLoading(), !loader.hasFatalError(),
                  playlistSnapshot?.hasEndTag != true else {
                return
            }

            // Loading it is asking for it again.
            excludeUntil = .zero
            let delay = earliestNextLoadTime - CMClock.hostTimeClock.time
            guard delay > .zero else {
                loadPlaylistImmediately(requestUrl: requestUrl)
                return
            }
            isLoadPending = true
            pendingRequestUrl = requestUrl
            reloadTimer.schedule(deadline: .now() + delay.seconds)
        }

        func maybeThrowError() throws {
            try loader.maybeThrowError(minRetryCount: tracker.minRetryCount)
            if let loadError { throw loadError }
            if let playlistError { throw playlistError }
        }

        func exclude(for duration: CMTime) {
            excludeUntil = CMClock.hostTimeClock.time + duration
        }

        func isExcluded(at time: CMTime) -> Bool {
            time < excludeUntil
        }

        func release() {
            isReleased = true
            reloadTimer.cancel()
            loader.release()
        }

        func processLoadedPlaylist(_ loaded: HlsMediaPlaylist, loadDuration: CMTime) {
            let now = CMClock.hostTimeClock.time
            let old = playlistSnapshot
            let (snapshot, changed) = tracker.latestPlaylistSnapshot(old: old, loaded: loaded)
            playlistSnapshot = snapshot
            lastSnapshotLoadTime = now
            logSnapshot(snapshot, changed: changed, loadDuration: loadDuration)

            if changed {
                playlistError = nil
                lastSnapshotChangeTime = now
                tracker.onPlaylistUpdated(url: url, playlist: snapshot)
            } else if !snapshot.hasEndTag {
                var error: Error?
                // A server that started over is asked again: another variant won't help.
                var forceRetry = false
                let stuckDuration = CMTimeMultiplyByFloat64(
                    snapshot.targetDuration,
                    multiplier: Self.playlistStuckTargetDurationCoefficient
                )
                if loaded.endMediaSequence < snapshot.mediaSequence {
                    error = PlaylistResetError(url: url)
                    forceRetry = true
                } else if now - lastSnapshotChangeTime > stuckDuration {
                    error = PlaylistStuckError(url: url)
                }
                if let error {
                    SELogger.warning(.playlist, "\(logName): \(error)")
                    playlistError = error
                    tracker.notifyPlaylistError(
                        url: url,
                        errorInfo: LoadErrorInfo(dataType: .manifest, error: error, errorCount: 1),
                        forceRetry: forceRetry
                    )
                }
            }

            // A new snapshot can't change again for a target duration; an unchanged one is asked for again sooner. A
            // server that blocks reloads holds the next request until the playlist changes, so it goes out at once,
            // unless the server answered without waiting.
            let canBlockReload = snapshot.serverControl.canBlockReload
            let reloadInterval = canBlockReload && snapshot.isLowLatency
                ? snapshot.partTargetDuration
                : snapshot.targetDuration
            let durationUntilNextLoad: CMTime = if !changed {
                CMTimeMultiplyByRatio(reloadInterval, multiplier: 1, divisor: 2)
            } else if canBlockReload {
                .zero
            } else {
                reloadInterval
            }
            earliestNextLoadTime = now + durationUntilNextLoad - loadDuration
            // A full playlist came: the next reload may skip and block again.
            allowsDeliveryDirectives = true
            // The primary playlist and those that play reload by themselves; the others when a chunk source needs
            // them.
            if tracker.isPrimary(url) || isActiveForPlayback, !snapshot.hasEndTag {
                loadPlaylist()
            }
        }

        private func loadPlaylistImmediately(requestUrl: URL? = nil) {
            guard !isReleased, !loader.isLoading(), !loader.hasFatalError() else {
                return
            }
            let requestUrl = requestUrl ?? reloadUrl
            SELogger.verbose(.playlist, "Loading \(logName)\(requestUrl.query.map { " (\($0))" } ?? "")")
            loadError = nil
            loader.startLoading(
                loadable: tracker.makeLoadable(
                    url: requestUrl,
                    multivariantPlaylist: tracker.multivariantPlaylist,
                    previousMediaPlaylist: playlistSnapshot,
                    isBlockingReload: Self.isBlockingRequest(requestUrl)
                ),
                callback: self,
                defaultMinRetryCount: tracker.minRetryCount
            )
        }

        /// The url the playlist reloads from. A server that blocks reloads is asked for the segment after the last
        /// one, and in a low-latency playlist for the part after the last one: it answers once the playlist has it.
        /// A server that skips segments is asked for a delta update while the snapshot is recent enough for it.
        private var reloadUrl: URL {
            guard allowsDeliveryDirectives, let snapshot = playlistSnapshot, !snapshot.hasEndTag else {
                return url
            }
            var queryItems: [URLQueryItem] = []
            if snapshot.serverControl.canBlockReload {
                let nextMediaSequence = String(snapshot.endMediaSequence)
                queryItems.append(URLQueryItem(name: Self.mediaSequenceParameter, value: nextMediaSequence))
                if snapshot.isLowLatency {
                    let availableParts = snapshot.trailingParts.filter { !$0.isPreload }.count
                    queryItems.append(URLQueryItem(name: Self.partParameter, value: String(availableParts)))
                }
            }
            // The snapshot must be no older than half the skip boundary for the server to skip on it.
            let skipUntil = snapshot.serverControl.skipUntil
            let snapshotAge = CMClock.hostTimeClock.time - lastSnapshotLoadTime
            if skipUntil.isNumeric, snapshotAge < CMTimeMultiplyByRatio(skipUntil, multiplier: 1, divisor: 2) {
                queryItems.append(URLQueryItem(
                    name: Self.skipParameter,
                    value: snapshot.serverControl.canSkipDateRanges ? "v2" : "YES"
                ))
            }
            return Self.appending(queryItems, to: url)
        }

        // MARK: Loader.Callback

        func onLoadStarted(
            loadable: ParsingLoadable<HlsParsedPlaylist>,
            onTime: DispatchTime,
            loadDuration: DispatchTimeInterval,
            retryCount: Int
        ) {}

        func onLoadCompleted(
            loadable: ParsingLoadable<HlsParsedPlaylist>,
            onTime: DispatchTime,
            loadDuration: DispatchTimeInterval
        ) {
            guard case let .media(playlist) = loadable.result else {
                let error = ParserError.createForMalformedManifest(message: "Loaded playlist has unexpected type.")
                loadError = error
                tracker.notifyPlaylistError(
                    url: url,
                    errorInfo: LoadErrorInfo(dataType: .manifest, error: error, errorCount: 1),
                    forceRetry: true
                )
                return
            }
            processLoadedPlaylist(playlist, loadDuration: loadDuration.time)
        }

        func onLoadCancelled(
            loadable: ParsingLoadable<HlsParsedPlaylist>,
            onTime: DispatchTime,
            loadDuration: DispatchTimeInterval,
            released: Bool
        ) {}

        func onLoadError(
            loadable: ParsingLoadable<HlsParsedPlaylist>,
            onTime: DispatchTime,
            loadDuration: DispatchTimeInterval,
            error: Error,
            errorCount: Int
        ) -> Loader.LoadErrorAction {
            // A server that can't block or skip for this request, or a delta update the snapshot can't take: a full
            // playlist, asked for at once, follows.
            let responseCode = (error as? InvalidResponseCodeError)?.responseCode
            let isDeltaUpdateUnusable = if case .deltaUpdateUnusable = error as? HlsPlaylistParser.ParseError {
                true
            } else {
                false
            }
            let usedDeliveryDirectives = loadable.dataSpec.url != url
            if usedDeliveryDirectives, isDeltaUpdateUnusable || responseCode == 400 || responseCode == 503 {
                SELogger.warning(
                    .playlist,
                    "HLS playlist \(logName) can't be loaded with delivery directives, loading it in full: \(error)"
                )
                allowsDeliveryDirectives = false
                earliestNextLoadTime = .zero
                tracker.queue.justDispatch { [weak self] in self?.loadPlaylist() }
                return .dontRetry
            }

            let errorInfo = LoadErrorInfo(dataType: .manifest, error: error, errorCount: errorCount)
            // A playlist whose track the players stopped playing doesn't load again until they need it.
            guard tracker.notifyPlaylistError(url: url, errorInfo: errorInfo, forceRetry: false) else {
                SELogger.warning(.playlist, "HLS playlist \(logName) excluded: \(error)")
                return .dontRetry
            }
            guard let retryDelay = tracker.loadErrorHandlingPolicy.getRetryDelay(for: errorInfo) else {
                SELogger.error(.playlist, "HLS playlist \(logName) failed with a fatal error, not retrying: \(error)")
                return .dontRetryFatal
            }
            SELogger.warning(
                .playlist,
                "HLS playlist \(logName) failed (attempt \(errorCount)), "
                    + "retrying in \(retryDelay.totalMilliseconds)ms: \(error)"
            )
            return .createRetryAction(resetErrorCount: false, retryDelay: retryDelay)
        }

        // MARK: Helpers

        /// The playlist's name in logs: with its directory, as renditions often share a file name.
        private var logName: String {
            let directory = url.deletingLastPathComponent().lastPathComponent
            guard !directory.isEmpty, directory != "/" else { return url.lastPathComponent }
            return "\(directory.prefix(12))/\(url.lastPathComponent)"
        }

        private func logSnapshot(_ snapshot: HlsMediaPlaylist, changed: Bool, loadDuration: CMTime) {
            let availableParts = snapshot.trailingParts.filter { !$0.isPreload }.count
            SELogger.debug(
                .playlist,
                "\(logName)\(tracker.isPrimary(url) ? " (primary)" : ""): \(changed ? "changed" : "unchanged"), "
                    + "sequence \(snapshot.mediaSequence)–\(snapshot.endMediaSequence - 1)"
                    + (snapshot.trailingParts.isEmpty ? "" : " + \(availableParts) parts")
                    + ", \(snapshot.hasEndTag ? "ended" : "live"), loaded in \(loadDuration.seconds)s"
            )
        }
    }
}

private extension HlsPlaylistTracker.MediaPlaylistBundle {
    /// How many target durations a live playlist may stay the same before it counts as stuck.
    static let playlistStuckTargetDurationCoefficient = 3.5
    /// How long a snapshot of a live playlist stays valid at least.
    static let minSnapshotValidityDuration = CMTime(value: 30, timescale: 1)

    static let mediaSequenceParameter = "_HLS_msn"
    static let partParameter = "_HLS_part"
    static let skipParameter = "_HLS_skip"

    /// A blocking request for the segment with `mediaSequence`, and its part at `partIndex`.
    static func blockingRequestUrl(for url: URL, mediaSequence: Int, partIndex: Int?) -> URL {
        var queryItems = [URLQueryItem(name: mediaSequenceParameter, value: String(mediaSequence))]
        if let partIndex {
            queryItems.append(URLQueryItem(name: partParameter, value: String(partIndex)))
        }
        return appending(queryItems, to: url)
    }

    /// The url with more query items. Its own query, as a session id, stays.
    static func appending(_ queryItems: [URLQueryItem], to url: URL) -> URL {
        guard !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? url
    }

    static func isBlockingRequest(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == mediaSequenceParameter } ?? false
    }
}

private extension DispatchTimeInterval {
    var time: CMTime { CMTime(value: totalNanoseconds, timescale: 1_000_000_000) }
}
