//
//  HlsMediaChunk.swift
//  SEPlayer
//

import CoreMedia
import DataSource
import Extractor
import Foundation
import SEPlayerCommon

/// Where an ``HlsMediaChunk`` writes its samples.
protocol HlsMediaChunkOutput: AnyObject, ExtractorOutput {
    /// Called on the loading thread before the chunk extracts samples.
    ///
    /// - Parameters:
    ///   - shouldSpliceIn: Whether the samples of the chunk overlap those already queued, and replace them from
    ///     their first keyframe on.
    ///   - reusingExtractor: Whether the chunk goes on with the extractor of the chunk before it. A new extractor
    ///     declares its tracks again.
    func prepare(chunkUid: Int, shouldSpliceIn: Bool, reusingExtractor: Bool)
}

/// A key and an initialization vector for AES-128 decryption.
struct HlsSegmentKey: Hashable, Sendable {
    let key: Data
    let iv: Data
}

/// An HLS media chunk: a segment or a part of one, with its initialization section when the extractor needs it.
final class HlsMediaChunk: MediaChunk, @unchecked Sendable {
    /// Identifies the chunk among those of the period.
    let uid: Int
    /// The index of the part the chunk loads in its segment, or `nil` if it loads the whole segment.
    let partIndex: Int?
    /// The discontinuity sequence number of the chunk.
    let discontinuitySequence: Int
    /// The url of the media playlist of the chunk.
    let playlistUrl: URL
    /// Whether the samples of the chunk overlap those already queued.
    var shouldSpliceIn: Bool { lock.withLock { _shouldSpliceIn } }
    /// Whether the chunk starts with a keyframe.
    let isIndependent: Bool
    /// Whether a preload hint announced the part the chunk loads: the playlist may still replace it.
    let isPreload: Bool
    /// Whether the segment or part is a gap: nothing of it loads.
    let hasGapTag: Bool
    /// Whether the playlist confirmed the part a preload hint announced. Always for a chunk that isn't a preload.
    var isPublished: Bool { lock.withLock { _isPublished } }
    /// The data spec of the initialization section, or `nil` if there is none.
    let initDataSpec: DataSpec?
    /// Whether the chunk is a single keyframe of an I-frame playlist. Its byte range ends inside the fragment or the
    /// packets that hold the keyframe, so only the first sample is kept, and the input may end in the next one.
    let isIFrameOnly: Bool

    /// The index of the first sample the chunk writes to each sample queue, set when its load starts.
    var firstSampleIndices: [Int] = []

    /// The extractor of the chunk, once it has one, unless the chunk after it can't go on with it.
    var extractor: HlsMediaChunkExtractor? { lock.withLock { isExtractorInvalidated ? nil : _extractor } }

    override var isLoadCompleted: Bool { lock.withLock { loadCompleted } }

    private let format: Format
    /// The format of the variant or rendition as the playlist declares it, with all its codecs: the extractor tells
    /// from it which streams of the segment there are.
    private let playlistFormat: Format
    /// The closed captions in the video, as the playlist declares them; `nil` if it doesn't.
    private let closedCaptionFormats: [Format]?
    /// The queue the load runs on, which extractors and their input assert.
    private let extractorQueue: Queue
    private let dataSourceFactory: DataSourceFactory
    /// The memory of decrypted bytes, for an encrypted segment.
    private let decryptionMemoryPool: CMMemoryPool
    private let extractorFactory: HlsExtractorFactory
    private let isMasterTimestampSource: Bool
    private let timestampAdjuster: TimestampAdjuster
    private let mediaKey: HlsSegmentKey?
    private let initKey: HlsSegmentKey?
    private let previousExtractor: HlsMediaChunkExtractor?
    private let transferListener: TransferListener?
    private weak var output: HlsMediaChunkOutput?

    private let lock = UnfairLock()
    // All guarded by lock.
    private var _extractor: HlsMediaChunkExtractor?
    private var loadCompleted = false
    private var initDataLoadRequired: Bool
    private var timestampSession: TimestampAdjuster.Session?
    private var isRetry = false
    private var _shouldSpliceIn: Bool
    private var _isPublished: Bool
    private var isExtractorInvalidated = false

    init(
        uid: Int,
        dataSpec: DataSpec,
        format: Format,
        trackSelectionReason: TrackSelectionReason,
        trackSelectionData: Any?,
        startTime: CMTime,
        endTime: CMTime,
        mediaSequence: Int,
        partIndex: Int? = nil,
        discontinuitySequence: Int,
        playlistUrl: URL,
        initDataSpec: DataSpec?,
        mediaKey: HlsSegmentKey?,
        initKey: HlsSegmentKey?,
        isMasterTimestampSource: Bool,
        timestampAdjuster: TimestampAdjuster,
        previousChunk: HlsMediaChunk?,
        playlistFormat: Format? = nil,
        shouldSpliceIn: Bool = false,
        isIndependent: Bool = true,
        isPreload: Bool = false,
        hasGapTag: Bool = false,
        loaderQueue: Queue,
        dataSourceFactory: DataSourceFactory,
        decryptionMemoryPool: CMMemoryPool,
        extractorFactory: HlsExtractorFactory,
        transferListener: TransferListener?,
        closedCaptionFormats: [Format]? = nil,
        isIFrameOnly: Bool = false
    ) {
        self.isIFrameOnly = isIFrameOnly
        self.closedCaptionFormats = closedCaptionFormats
        self.uid = uid
        self.partIndex = partIndex
        self.transferListener = transferListener
        self.extractorQueue = loaderQueue
        self.format = format
        self.playlistFormat = playlistFormat ?? format
        self.discontinuitySequence = discontinuitySequence
        self.playlistUrl = playlistUrl
        self.initDataSpec = initDataSpec
        self.mediaKey = mediaKey
        self.initKey = initKey
        self.isMasterTimestampSource = isMasterTimestampSource
        self.timestampAdjuster = timestampAdjuster
        self.dataSourceFactory = dataSourceFactory
        self.decryptionMemoryPool = decryptionMemoryPool
        self.extractorFactory = extractorFactory

        _shouldSpliceIn = shouldSpliceIn
        self.isIndependent = isIndependent
        self.isPreload = isPreload
        self.hasGapTag = hasGapTag
        _isPublished = !isPreload

        // A chunk that follows a loaded chunk of the same rendition continues its samples.
        let isFollowingChunk = previousChunk.map { $0.playlistUrl == playlistUrl && $0.isLoadCompleted } ?? false

        // Within a discontinuity, the extractor goes on from chunk to chunk.
        if let previousChunk, isFollowingChunk, previousChunk.discontinuitySequence == discontinuitySequence,
           let extractor = previousChunk.extractor, extractor.isReusable {
            previousExtractor = extractor
            initDataLoadRequired = initDataSpec != nil && initDataSpec != previousChunk.initDataSpec
        } else {
            previousExtractor = nil
            initDataLoadRequired = initDataSpec != nil
        }

        super.init(
            dataSpec: dataSpec,
            trackFormat: format,
            trackSelectionReason: trackSelectionReason,
            trackSelectionData: trackSelectionData,
            startTime: startTime,
            endTime: endTime,
            chunkIndex: mediaSequence
        )
    }

    /// Marks the part a preload hint announced as confirmed by the playlist.
    func publish() {
        lock.withLock { _isPublished = true }
    }

    /// Makes the chunk a clean start rather than a splice: what it overlapped was discarded.
    func clearShouldSpliceIn() {
        lock.withLock { _shouldSpliceIn = false }
    }

    /// Stops the chunk after this one from going on with this chunk's extractor, as when the chunks after this one
    /// were discarded and the extractor read further.
    func invalidateExtractor() {
        lock.withLock { isExtractorInvalidated = true }
    }

    /// Sets where the chunk writes its samples. Called before the load starts.
    func initialize(output: HlsMediaChunkOutput) {
        self.output = output
    }

    /// Starts the chunk over on its next load, after a failed one: with a new extractor, as the old one stopped
    /// somewhere in the data, and splicing the samples into those it already queued.
    func prepareForRetry() {
        lock.withLock {
            isRetry = true
            _extractor = nil
            timestampSession = nil
            initDataLoadRequired = initDataSpec != nil
        }
    }

    override func load(_ isolation: isolated any Actor) async throws {
        guard let output else { throw ErrorBuilder.illegalState() }

        let (reusingExtractor, loadInitData, spliceIn) = lock.withLock { () -> (Bool, Bool, Bool) in
            if _extractor == nil, !isRetry, let previousExtractor {
                _extractor = previousExtractor
            }
            let reusing = _extractor != nil && _extractor === previousExtractor
            return (reusing, initDataLoadRequired, _shouldSpliceIn || isRetry)
        }
        output.prepare(chunkUid: uid, shouldSpliceIn: spliceIn, reusingExtractor: reusingExtractor)
        // One for the load: the extractor made while reading the initialization section goes on with it.
        let firstSampleOutput = isIFrameOnly ? FirstSampleOutput(output, keyframeDuration: endTime - startTime) : nil

        if loadInitData, let initDataSpec {
            try await feed(
                dataSpec: initDataSpec,
                key: initKey,
                output: output,
                firstSampleOutput: firstSampleOutput,
                isolation
            )
            lock.withLock { initDataLoadRequired = false }
        }
        try Task.checkCancellation()

        // A gap has no media to load: the server may not have it at all.
        if !hasGapTag {
            try await feed(
                dataSpec: dataSpec,
                key: mediaKey,
                output: output,
                firstSampleOutput: firstSampleOutput,
                isolation
            )
        }
        lock.withLock { loadCompleted = true }
    }

    /// Reads the data through the extractor, making one first if the chunk doesn't have one.
    ///
    /// - Parameter firstSampleOutput: For a keyframe chunk, the output that keeps only the first sample.
    private func feed(
        dataSpec: DataSpec,
        key: HlsSegmentKey?,
        output: HlsMediaChunkOutput,
        firstSampleOutput: FirstSampleOutput?,
        _ isolation: isolated any Actor
    ) async throws {
        let dataSource = dataSourceFactory.createDataSource(transferListener: transferListener)
        do {
            _ = try await dataSource.open(dataSpec: dataSpec, isolation)
            let end = dataSpec.length.map { dataSpec.position + $0 }
            let reader: DataReader = if let key {
                try Aes128DataReader(
                    upstream: dataSource,
                    start: dataSpec.position,
                    end: end,
                    key: key.key,
                    iv: key.iv,
                    memoryPool: decryptionMemoryPool
                )
            } else {
                BoundedDataReader(upstream: dataSource, end: end)
            }
            let input = DefaultExtractorInput(
                queue: extractorQueue,
                dataReader: reader,
                position: dataSpec.position,
                length: key == nil ? end : nil
            )

            let extractor = try await prepareExtractor(
                input: input,
                output: firstSampleOutput ?? WeakExtractorOutput(output),
                isolation
            )
            var result = ExtractorReadResult.continueRead
            do {
                while result == .continueRead, firstSampleOutput?.hasSample != true {
                    try Task.checkCancellation()
                    result = try await extractor.extractor.read(input: input, isolation)
                }
            } catch where firstSampleOutput?.hasSample == true && !(error is CancellationError) {
                // The keyframe is out; the byte range ended in what follows it.
            }
            let bytes = input.getPosition(isolation) - dataSpec.position
            addBytesLoaded(bytes)
        } catch {
            try? await dataSource.close(isolation)
            throw error
        }
        try? await dataSource.close(isolation)
    }

    private func prepareExtractor(
        input: DefaultExtractorInput,
        output: ExtractorOutput,
        _ isolation: isolated any Actor
    ) async throws -> HlsMediaChunkExtractor {
        if let extractor = lock.withLock({ _extractor }), extractor.isInitialized {
            return extractor
        }

        // Samples only come after the timeline of the discontinuity is set: by this chunk if it is the master
        // timestamp source, otherwise by the master chunk of the same discontinuity.
        if !isMasterTimestampSource {
            try await timestampAdjuster.awaitOffset()
        }
        let session = lock.withLock { () -> TimestampAdjuster.Session in
            if let timestampSession { return timestampSession }
            let session = timestampAdjuster.makeSession(desiredFirstSampleTime: startTime)
            timestampSession = session
            return session
        }

        let extractor = try await extractorFactory.createExtractor(
            url: dataSpec.url,
            format: playlistFormat,
            closedCaptionFormats: closedCaptionFormats,
            timestampSession: session,
            input: input,
            isolation
        )
        // The wrapper keeps the chunks, and they keep their extractors: the extractor mustn't keep the wrapper.
        try await extractor.extractor.initialize(output: output, isolation)
        extractor.isInitialized = true
        lock.withLock { _extractor = extractor }
        return extractor
    }
}

/// Passes what an extractor outputs to a chunk output without keeping it.
private final class WeakExtractorOutput: ExtractorOutput {
    private weak var target: HlsMediaChunkOutput?

    init(_ target: HlsMediaChunkOutput) {
        self.target = target
    }

    func track(for id: Int, trackType: TrackType) throws -> TrackOutput {
        guard let target else { throw CancellationError() }
        return try target.track(for: id, trackType: trackType)
    }

    func endTracks() {
        target?.endTracks()
    }

    func seekMap(seekMap: SeekMap) {
        target?.seekMap(seekMap: seekMap)
    }
}

/// Passes the tracks and the first video sample an extractor outputs to a chunk output, without keeping it, and drops
/// the samples after it: those of a keyframe's byte range that ends inside the next sample. The samples of other tracks,
/// as the audio and the captions an MPEG-TS keyframe's range holds too, are dropped: they may come before the keyframe.
///
/// The keyframe stands for its whole segment of the I-frame playlist, until the next one: it lasts as long. A seek to a
/// time inside the segment shows it, rather than taking it for a frame that ended before the position, as a frame's own
/// duration would.
private final class FirstSampleOutput: ExtractorOutput {
    /// Whether a sample is out.
    var hasSample: Bool { lock.withLock { _hasSample } }

    /// How long the keyframe shows: its segment's duration.
    let keyframeDuration: CMTime

    private let target: WeakExtractorOutput
    private let lock = UnfairLock()
    private var _hasSample = false

    init(_ target: HlsMediaChunkOutput, keyframeDuration: CMTime) {
        self.target = WeakExtractorOutput(target)
        self.keyframeDuration = keyframeDuration
    }

    func track(for id: Int, trackType: TrackType) throws -> TrackOutput {
        FirstSampleTrackOutput(
            output: try target.track(for: id, trackType: trackType),
            owner: self,
            isVideo: trackType == .video
        )
    }

    func endTracks() {
        target.endTracks()
    }

    func seekMap(seekMap: SeekMap) {
        target.seekMap(seekMap: seekMap)
    }

    /// Whether a track may output another sample: only until the first one is out.
    fileprivate func takesSamples() -> Bool {
        !hasSample
    }

    fileprivate func didOutputSample() {
        lock.withLock { _hasSample = true }
    }
}

private final class FirstSampleTrackOutput: TrackOutput {
    private let output: TrackOutput
    private let owner: FirstSampleOutput
    /// Whether the track outputs the keyframe: the others' samples are dropped.
    private let isVideo: Bool

    init(output: TrackOutput, owner: FirstSampleOutput, isVideo: Bool) {
        self.output = output
        self.owner = owner
        self.isVideo = isVideo
    }

    func setDuration(_ duration: CMTime) {
        output.setDuration(duration)
    }

    func setFormat(_ format: Format) throws {
        try output.setFormat(format)
    }

    func sampleData(data: CMBlockBuffer) throws {
        guard isVideo, owner.takesSamples() else { return }
        try output.sampleData(data: data)
    }

    func sampleMetadata(time: CMSampleTimingInfo, flags: SampleFlags, range: Range<Int>) throws {
        guard isVideo, owner.takesSamples() else { return }
        var time = time
        if owner.keyframeDuration.isNumeric, owner.keyframeDuration > .zero,
           !time.duration.isNumeric || time.duration < owner.keyframeDuration {
            time.duration = owner.keyframeDuration
        }
        try output.sampleMetadata(time: time, flags: flags, range: range)
        owner.didOutputSample()
    }
}
