//
//  HlsMediaPeriod.swift
//  SEPlayer
//

import CoreMedia
import DataSource
import Extractor
import Foundation
import SEPlayerCommon

/// A ``MediaPeriod`` that loads an HLS stream.
///
/// The variants load in one ``HlsSampleStreamWrapper``, each audio rendition group in another, and each subtitle
/// rendition in one of its own. Subtitles are parsed into cues as they load.
///
/// Runs on the player queue.
final class HlsMediaPeriod: MediaPeriod {
    var trackGroups: TrackGroupArray { _trackGroups ?? .empty }

    var isLoading: Bool { enabledWrappers.contains { $0.isLoading } }

    var keepsStreamsForSelectionsInSameGroup: Bool { true }

    private let playlistTracker: HlsPlaylistTracker
    private let extractorFactory: HlsExtractorFactory
    private let subtitleParserFactory: SubtitleParserFactory
    private let dataSourceFactory: DataSourceFactory
    /// The memory of decrypted segments.
    private let decryptionMemoryPool: CMMemoryPool
    private let timestampAdjusterProvider: TimestampAdjusterProvider
    private let queue: Queue
    private let loaderQueue: Queue
    private let allowChunklessPreparation: Bool
    private let loadErrorHandlingPolicy: LoadErrorHandlingPolicy
    private let transferListener: TransferListener?
    /// Hears how many bytes the sample queues hold.
    private let allocator: Allocator?

    private var callback: (any MediaPeriodCallback)?
    private var wrappers: [HlsSampleStreamWrapper] = []
    private var enabledWrappers: [HlsSampleStreamWrapper] = []
    /// Whether only the frame at the position is needed, as while the user scrubs a paused player.
    private var isScrubbing = false
    /// Whether the next seek starts loading over: what scrubbing loaded only shows a frame.
    private var needsResetAfterScrubbing = false
    /// The number of wrappers that are audio or video: they can set the timeline of a discontinuity.
    private var audioVideoWrapperCount = 0
    private var pendingPrepareCount = 0
    private var _trackGroups: TrackGroupArray?
    private var streamWrapperIndices: [ObjectIdentifier: Int] = [:]
    private var released = false
    /// Why the wrappers couldn't be built from the multivariant playlist.
    private var prepareError: Error?

    init(
        playlistTracker: HlsPlaylistTracker,
        extractorFactory: HlsExtractorFactory,
        subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory(),
        dataSourceFactory: DataSourceFactory,
        decryptionMemoryPool: CMMemoryPool,
        timestampAdjusterProvider: TimestampAdjusterProvider,
        queue: Queue,
        loaderQueue: Queue,
        allowChunklessPreparation: Bool = true,
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy(),
        transferListener: TransferListener? = nil,
        allocator: Allocator? = nil
    ) {
        self.allocator = allocator
        self.transferListener = transferListener
        self.playlistTracker = playlistTracker
        self.extractorFactory = extractorFactory
        self.subtitleParserFactory = subtitleParserFactory
        self.dataSourceFactory = dataSourceFactory
        self.decryptionMemoryPool = decryptionMemoryPool
        self.timestampAdjusterProvider = timestampAdjusterProvider
        self.queue = queue
        self.loaderQueue = loaderQueue
        self.allowChunklessPreparation = allowChunklessPreparation
        self.loadErrorHandlingPolicy = loadErrorHandlingPolicy
    }

    func release() {
        assert(queue.isCurrent())
        released = true
        playlistTracker.listeners.removeDelegate(self)
        wrappers.forEach { $0.release() }
        callback = nil
    }

    // MARK: - MediaPeriod

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        assert(queue.isCurrent())
        self.callback = callback
        playlistTracker.listeners.addDelegate(self)
        do {
            try buildAndPrepareSampleStreamWrappers(position: time)
        } catch {
            SELogger.error(.hls, "HLS period can't prepare: \(error)")
            prepareError = error
        }
    }

    func maybeThrowPrepareError() throws {
        if let prepareError { throw prepareError }
        try wrappers.forEach { try $0.maybeThrowPrepareError() }
    }

    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        position: CMTime
    ) throws -> CMTime {
        assert(queue.isCurrent())

        // Which wrapper each stream and each selection belongs to.
        var streamChildIndices = [Int?](repeating: nil, count: selections.count)
        var selectionChildIndices = [Int?](repeating: nil, count: selections.count)
        for index in selections.indices {
            if let stream = streams[index] {
                streamChildIndices[index] = streamWrapperIndices[ObjectIdentifier(stream)]
            }
            if let selection = selections[index] {
                selectionChildIndices[index] = wrappers.firstIndex { $0.trackGroups.contains(selection.trackGroup) }
            }
        }
        streamWrapperIndices.removeAll()

        var newStreams = [SampleStream?](repeating: nil, count: selections.count)
        var newEnabledWrappers: [HlsSampleStreamWrapper] = []
        var forceReset = false

        for (wrapperIndex, wrapper) in wrappers.enumerated() {
            var childStreams = streams.indices.map { streamChildIndices[$0] == wrapperIndex ? streams[$0] : nil }
            let childSelections = selections.indices.map {
                selectionChildIndices[$0] == wrapperIndex ? selections[$0] : nil
            }

            let wasReset = try wrapper.selectTracks(
                selections: childSelections,
                mayRetainStreamFlags: mayRetainStreamFlags,
                streams: &childStreams,
                streamResetFlags: &streamResetFlags,
                position: position,
                forceReset: forceReset
            )

            var wrapperEnabled = false
            for index in selections.indices {
                if let stream = childStreams[index] {
                    newStreams[index] = stream
                    streamWrapperIndices[ObjectIdentifier(stream)] = wrapperIndex
                    wrapperEnabled = true
                } else if selectionChildIndices[index] == wrapperIndex {
                    assert(newStreams[index] == nil)
                }
            }

            guard wrapperEnabled else { continue }
            if newEnabledWrappers.isEmpty {
                // The first enabled wrapper always sets the timeline. If it was reset or another one took its place,
                // the timelines go and every wrapper starts over.
                wrapper.setIsTimestampMaster(true)
                if wasReset || enabledWrappers.first !== wrapper {
                    timestampAdjusterProvider.reset()
                    forceReset = true
                }
            } else {
                wrapper.setIsTimestampMaster(wrapperIndex < audioVideoWrapperCount)
            }
            newEnabledWrappers.append(wrapper)
        }

        streams = newStreams
        enabledWrappers = newEnabledWrappers
        return position
    }

    func updateSelectionsKeepingBuffer(_ selections: [SETrackSelection?], streams: [SampleStream?]) -> Bool {
        assert(queue.isCurrent())
        var replacements: [(wrapper: HlsSampleStreamWrapper, selection: SETrackSelection, trackGroupIndex: Int)] = []
        for index in selections.indices {
            switch (selections[index], streams[index]) {
            case (nil, nil):
                continue
            case let (selection?, stream?):
                guard let stream = stream as? HlsSampleStream,
                      let wrapperIndex = streamWrapperIndices[ObjectIdentifier(stream)] else {
                    return false
                }
                let wrapper = wrappers[wrapperIndex]
                guard wrapper.trackGroups.firstIndex(of: selection.trackGroup) == stream.trackGroupIndex else {
                    return false
                }
                replacements.append((wrapper, selection, stream.trackGroupIndex))
            default:
                return false
            }
        }
        replacements.forEach { $0.wrapper.replaceTrackSelection($0.selection, trackGroupIndex: $0.trackGroupIndex) }
        return true
    }

    func discardBuffer(position: CMTime, toKeyframe: Bool) throws {
        try enabledWrappers.forEach { try $0.discardBuffer(position: position, toKeyframe: toKeyframe) }
    }

    func readDiscontinuity() -> CMTime { .invalid }

    func seek(position: CMTime) throws -> CMTime {
        guard let first = enabledWrappers.first else { return position }
        let mustReset = needsResetAfterScrubbing
        needsResetAfterScrubbing = false
        // The wrapper that sets the timeline goes first: if it resets, so do the others.
        let forceReset = try first.seek(to: position, forceReset: mustReset) || mustReset
        for wrapper in enabledWrappers.dropFirst() {
            _ = try wrapper.seek(to: position, forceReset: forceReset)
        }
        if forceReset {
            timestampAdjusterProvider.reset()
        }
        return position
    }

    /// Restarts from where a renderer lost its output: inside the buffer while it still holds the position, which
    /// the back buffer keeps for a while, or else by loading again from there.
    func seekForRecovery(position: CMTime) throws -> CMTime {
        try seek(position: position)
    }

    func setScrubbing(_ isScrubbing: Bool) {
        guard isScrubbing != self.isScrubbing else { return }
        self.isScrubbing = isScrubbing
        wrappers.forEach { $0.setScrubbing(isScrubbing) }
        if !isScrubbing {
            needsResetAfterScrubbing = true
        }
    }

    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        // Only the variants know where their segments start.
        guard let wrapper = enabledWrappers.first(where: { $0.trackType == .unknown }) else {
            return position
        }
        return wrapper.getAdjustedSeekPosition(position: position, seekParameters: seekParameters)
    }

    // MARK: - SequenceableLoader

    func getBufferedPosition() -> CMTime {
        minimumPosition(enabledWrappers.map { $0.getBufferedPosition() })
    }

    func getNextLoadPosition() -> CMTime {
        minimumPosition(enabledWrappers.map { $0.getNextLoadPosition() })
    }

    @discardableResult
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
        guard _trackGroups != nil else {
            // Preparing: the wrappers load what they need.
            wrappers.forEach { $0.continuePreparing() }
            return false
        }

        // Scrubbing with keyframes needs only the variants: the renditions would take bandwidth from them.
        let variantWrappers = enabledWrappers.filter { $0.trackType == .unknown }
        let scrubsWithIFrames = isScrubbing && variantWrappers.contains { $0.scrubsWithIFrames }
        let loadingWrappers = scrubsWithIFrames ? variantWrappers : enabledWrappers

        // The wrappers that are furthest behind load first.
        var madeProgress = false
        var madeProgressThisIteration: Bool
        repeat {
            madeProgressThisIteration = false
            let nextLoadPosition = minimumPosition(loadingWrappers.map { $0.getNextLoadPosition() })
            guard !nextLoadPosition.isPositiveInfinity else { break }
            for wrapper in loadingWrappers {
                let wrapperNextLoadPosition = wrapper.getNextLoadPosition()
                let isBehind = !wrapperNextLoadPosition.isPositiveInfinity
                    && wrapperNextLoadPosition <= loadingInfo.playbackPosition
                if wrapperNextLoadPosition == nextLoadPosition || isBehind {
                    madeProgressThisIteration = wrapper.continueLoading(with: loadingInfo) || madeProgressThisIteration
                }
            }
            madeProgress = madeProgress || madeProgressThisIteration
        } while madeProgressThisIteration
        return madeProgress
    }

    func stopLoading() {}

    func reevaluateBuffer(position: CMTime) {
        enabledWrappers.forEach { $0.reevaluateBuffer(position: position) }
    }

    // MARK: - Building wrappers

    private func buildAndPrepareSampleStreamWrappers(position: CMTime) throws {
        guard let multivariantPlaylist = playlistTracker.multivariantPlaylist else {
            throw ErrorBuilder.illegalState()
        }

        if !multivariantPlaylist.variants.isEmpty {
            try buildAndPrepareMainSampleStreamWrapper(multivariantPlaylist: multivariantPlaylist, position: position)
        }
        try buildAndPrepareAudioSampleStreamWrappers(multivariantPlaylist: multivariantPlaylist, position: position)
        audioVideoWrapperCount = wrappers.count
        try buildAndPrepareSubtitleSampleStreamWrappers(multivariantPlaylist: multivariantPlaylist, position: position)

        pendingPrepareCount = wrappers.count
        // Until tracks are selected, any audio or video wrapper may set the timeline of a discontinuity: a wrapper
        // that loads a chunk to prepare would otherwise wait for one that doesn't load.
        wrappers.prefix(audioVideoWrapperCount).forEach { $0.setIsTimestampMaster(true) }
        // Wrappers that couldn't prepare from the playlist load their first chunk; until preparation completes
        // they all load.
        enabledWrappers = wrappers
        wrappers.forEach { $0.continuePreparing() }
    }

    private func buildAndPrepareMainSampleStreamWrapper(
        multivariantPlaylist: HlsMultivariantPlaylist,
        position: CMTime
    ) throws {
        // Variants with video make the main stream; audio-only variants are left out then.
        var variants = multivariantPlaylist.variants
        let videoVariants = variants.filter {
            VideoFormat($0.format)?.size != nil || Codecs.ofType($0.format.codecs, trackType: .video) != nil
        }
        if !videoVariants.isEmpty {
            variants = videoVariants
        }

        let codecs = variants[0].format.codecs
        let videoCodecCount = Codecs.split(Codecs.ofType(codecs, trackType: .video)).count
        let audioCodecCount = Codecs.split(Codecs.ofType(codecs, trackType: .audio)).count
        let codecsAllowChunklessPreparation = audioCodecCount <= 1 && videoCodecCount <= 1
            && audioCodecCount + videoCodecCount > 0

        let wrapper = try makeSampleStreamWrapper(
            uid: "main",
            trackType: .unknown,
            playlistUrls: variants.map(\.url),
            playlistFormats: variants.map(\.format),
            iFrameVariants: videoVariants.isEmpty ? [] : multivariantPlaylist.iFrameVariants,
            muxedAudioFormat: multivariantPlaylist.muxedAudioFormat,
            closedCaptionFormats: multivariantPlaylist.muxedCaptionFormats,
            position: position
        )
        wrappers.append(wrapper)

        guard allowChunklessPreparation, codecsAllowChunklessPreparation else {
            return
        }

        var trackGroups: [TrackGroup] = []
        if videoCodecCount > 0 {
            try trackGroups.append(TrackGroup(id: "main", formats: variants.map { Self.deriveVideoFormat($0.format) }))
            if audioCodecCount > 0,
               multivariantPlaylist.muxedAudioFormat != nil || multivariantPlaylist.audios.isEmpty {
                let audioFormat = Self.deriveAudioFormat(
                    variantFormat: variants[0].format,
                    mediaTagFormat: multivariantPlaylist.muxedAudioFormat,
                    isPrimaryTrackInVariant: false
                )
                try trackGroups.append(TrackGroup(id: "main:audio", formats: [audioFormat]))
            }
            // The captions the playlist declares, as the cues parsed from them.
            for (index, captionFormat) in (multivariantPlaylist.muxedCaptionFormats ?? []).enumerated() {
                let trackFormat = try cuesFormat(of: AnyFormat(captionFormat))
                try trackGroups.append(TrackGroup(id: "main:cc:\(index)", formats: [trackFormat]))
            }
        } else {
            let audioFormats = variants.map {
                Self.deriveAudioFormat(
                    variantFormat: $0.format,
                    mediaTagFormat: multivariantPlaylist.muxedAudioFormat,
                    isPrimaryTrackInVariant: true
                )
            }
            try trackGroups.append(TrackGroup(id: "main", formats: audioFormats))
        }
        wrapper.prepareWithMultivariantPlaylistInfo(trackGroups: trackGroups, primaryTrackGroupIndex: 0)
    }

    private func buildAndPrepareAudioSampleStreamWrappers(
        multivariantPlaylist: HlsMultivariantPlaylist,
        position: CMTime
    ) throws {
        // Renditions with one name are one choice; their groups serve different variants.
        var names: [String] = []
        var renditionsByName: [String: [HlsMultivariantPlaylist.Rendition]] = [:]
        let loadableRenditions = multivariantPlaylist.audios.filter { rendition in
            rendition.url != nil && Self.isExtractable(rendition.format)
        }
        for rendition in loadableRenditions {
            if renditionsByName[rendition.name] == nil {
                names.append(rendition.name)
            }
            renditionsByName[rendition.name, default: []].append(rendition)
        }

        for name in names {
            guard let renditions = renditionsByName[name] else { continue }
            var urls: [URL] = []
            var formats: [AnyFormat] = []
            for rendition in renditions {
                guard let url = rendition.url, !urls.contains(url) else {
                    continue
                }
                urls.append(url)
                formats.append(rendition.format)
            }

            let wrapper = try makeSampleStreamWrapper(
                uid: "audio:\(name)",
                trackType: .audio,
                playlistUrls: urls,
                playlistFormats: formats,
                muxedAudioFormat: nil,
                position: position
            )
            wrappers.append(wrapper)

            let codecsKnown = formats.allSatisfy { Codecs.split($0.codecs).count == 1 }
            if allowChunklessPreparation, codecsKnown {
                try wrapper.prepareWithMultivariantPlaylistInfo(
                    trackGroups: [TrackGroup(id: "audio:\(name)", formats: formats)],
                    primaryTrackGroupIndex: 0
                )
            }
        }
    }

    private func buildAndPrepareSubtitleSampleStreamWrappers(
        multivariantPlaylist: HlsMultivariantPlaylist,
        position: CMTime
    ) throws {
        for (index, rendition) in multivariantPlaylist.subtitles.enumerated() {
            guard let url = rendition.url else { continue }
            let uid = "subtitle:\(index):\(rendition.name)"
            let wrapper = try makeSampleStreamWrapper(
                uid: uid,
                trackType: .text,
                playlistUrls: [url],
                playlistFormats: [rendition.format],
                muxedAudioFormat: nil,
                position: position
            )
            wrappers.append(wrapper)
            try wrapper.prepareWithMultivariantPlaylistInfo(
                trackGroups: [TrackGroup(id: uid, formats: [cuesFormat(of: rendition.format)])],
                primaryTrackGroupIndex: 0
            )
        }
    }

    private func makeSampleStreamWrapper(
        uid: String,
        trackType: TrackType,
        playlistUrls: [URL],
        playlistFormats: [AnyFormat],
        iFrameVariants: [HlsMultivariantPlaylist.Variant] = [],
        muxedAudioFormat: AnyFormat?,
        closedCaptionFormats: [TextFormat]? = nil,
        position: CMTime
    ) throws -> HlsSampleStreamWrapper {
        let chunkSource = try HlsChunkSource(
            extractorFactory: extractorFactory,
            playlistTracker: playlistTracker,
            playlistUrls: playlistUrls,
            playlistFormats: playlistFormats,
            dataSourceFactory: dataSourceFactory,
            decryptionMemoryPool: decryptionMemoryPool,
            timestampAdjusterProvider: timestampAdjusterProvider,
            loaderQueue: loaderQueue,
            transferListener: transferListener,
            iFrameVariants: iFrameVariants,
            closedCaptionFormats: closedCaptionFormats
        )
        return HlsSampleStreamWrapper(
            uid: uid,
            trackType: trackType,
            callback: self,
            chunkSource: chunkSource,
            positionUs: position,
            muxedAudioFormat: muxedAudioFormat,
            queue: queue,
            loaderQueue: loaderQueue,
            loadErrorHandlingPolicy: loadErrorHandlingPolicy,
            allocator: allocator
        )
    }

    /// The format of the cues parsed from subtitles or captions of the format, when they can be parsed: the samples
    /// are then the cues.
    private func cuesFormat(of format: AnyFormat) throws -> AnyFormat {
        guard let text = format.text, subtitleParserFactory.supportsFormat(text) else { return format }
        let behavior = try subtitleParserFactory.getCueReplacementBehavior(format: text)
        // The cues of the samples are timed relative to them.
        return AnyFormat(text.cuesFormat(cueReplacementBehavior: behavior).with { $0.subsampleOffset = nil })
    }

    /// The smallest position, with `.positiveInfinity` for the end of the source.
    private func minimumPosition(_ positions: [CMTime]) -> CMTime {
        positions.filter { !$0.isPositiveInfinity }.min() ?? .positiveInfinity
    }
}

private extension HlsMediaPeriod {
    /// The video track of a variant, as the playlist describes it.
    static func deriveVideoFormat(_ variantFormat: AnyFormat) -> AnyFormat {
        let codecs = Codecs.ofType(variantFormat.codecs, trackType: .video)
        let variant = variantFormat.video
        var format = VideoFormat()
        format.id = variantFormat.id
        format.label = variantFormat.label
        format.containerMimeType = variantFormat.containerMimeType
        format.codec = Codecs.mediaMimeType(ofType: .video, in: codecs).map(VideoCodec.init)
        format.codecs = codecs
        format.averageBitrate = variantFormat.averageBitrate
        format.peakBitrate = variantFormat.peakBitrate
        format.size = variant?.size
        format.frameRate = variant?.frameRate
        format.transferFunction = variant?.transferFunction
        format.selectionFlags = variantFormat.selectionFlags
        format.roleFlags = variantFormat.roleFlags
        return AnyFormat(format)
    }

    /// The audio track of a variant, as the playlist describes it, with what the rendition tag adds.
    static func deriveAudioFormat(
        variantFormat: AnyFormat,
        mediaTagFormat: AnyFormat?,
        isPrimaryTrackInVariant: Bool
    ) -> AnyFormat {
        let codecs = mediaTagFormat?.codecs ?? Codecs.ofType(variantFormat.codecs, trackType: .audio)
        var format = AudioFormat()
        format.id = mediaTagFormat?.id ?? variantFormat.id
        format.label = mediaTagFormat?.label ?? variantFormat.label
        format.containerMimeType = variantFormat.containerMimeType
        format.codec = Codecs.mediaMimeType(ofType: .audio, in: codecs).map(AudioCodec.init)
        format.codecs = codecs
        format.averageBitrate = isPrimaryTrackInVariant ? variantFormat.averageBitrate : nil
        format.peakBitrate = isPrimaryTrackInVariant ? variantFormat.peakBitrate : nil
        format.selectionFlags = mediaTagFormat?.selectionFlags ?? variantFormat.selectionFlags
        format.roleFlags = mediaTagFormat?.roleFlags ?? variantFormat.roleFlags
        format.language = mediaTagFormat?.language ?? variantFormat.language
        if let channelCount = mediaTagFormat.flatMap(AudioFormat.init)?.channelCount, channelCount > 0 {
            format.channelCount = channelCount
        }
        return AnyFormat(format)
    }

    /// The audio codecs the extractors don't read yet.
    static let unsupportedAudioTypes: Set<MimeTypes> = [.audioAC4, .audioDTS, .audioDTSHD, .audioDTSExpress, .audioDTSX]

    /// Whether the extractors can read the samples of the format. Formats without codecs might be readable.
    static func isExtractable(_ format: AnyFormat) -> Bool {
        !Codecs.split(format.codecs).contains { codec in
            Codecs.mediaMimeType(forCodec: codec).map(unsupportedAudioTypes.contains) ?? false
        }
    }
}

// MARK: - HlsSampleStreamWrapper.Callback

extension HlsMediaPeriod: HlsSampleStreamWrapper.Callback {
    func onPrepared(_ wrapper: HlsSampleStreamWrapper) {
        guard !released else { return }
        pendingPrepareCount -= 1
        guard pendingPrepareCount == 0 else { return }

        _trackGroups = TrackGroupArray(trackGroups: wrappers.flatMap { Array($0.trackGroups) })
        callback?.didPrepare(mediaPeriod: self)
    }

    func onPlaylistRefreshRequired(url: URL) {
        playlistTracker.refreshPlaylist(url: url)
    }

    func continueLoadingRequested(_ wrapper: HlsSampleStreamWrapper) {
        guard !released, _trackGroups != nil else { return }
        callback?.continueLoadingRequested(with: self)
    }
}

// MARK: - HlsPlaylistTracker.Listener

extension HlsMediaPeriod: HlsPlaylistTracker.Listener {
    func onPlaylistChanged() {
        wrappers.forEach { $0.onPlaylistUpdated() }
    }

    func onPlaylistError(url: URL, errorInfo: LoadErrorInfo, forceRetry: Bool) -> Bool {
        var exclusionSucceeded = true
        for wrapper in wrappers {
            exclusionSucceeded = wrapper.onPlaylistError(url: url, errorInfo: errorInfo, forceRetry: forceRetry)
                && exclusionSucceeded
        }
        // The player looks for the error, or loads from the track the selection switched to.
        if !released, _trackGroups != nil {
            callback?.continueLoadingRequested(with: self)
        }
        return exclusionSucceeded
    }
}
