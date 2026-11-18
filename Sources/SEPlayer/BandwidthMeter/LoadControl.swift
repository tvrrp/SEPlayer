//
//  LoadControl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.05.2025.
//

import CoreMedia
import Foundation.NSUUID
import SEPlayerCommon

public protocol LoadControl {
    var queue: Queue { get }
    func onPrepared(playerId: UUID)
    func onTracksSelected(parameters: LoadControlParams, trackGroups: TrackGroupArray, trackSelections: [SETrackSelection?])
    func onStopped(playerId: UUID)
    func onReleased(playerId: UUID)
    func getAllocator() -> Allocator
    func getBackBufferDuration(playerId: UUID) -> CMTime
    /// Loading restarts once less than this is buffered.
    func getMinBufferDuration(playerId: UUID) -> CMTime
    /// Loading may pause once this much is buffered.
    func getMaxBufferDuration(playerId: UUID) -> CMTime
    func retainBackBufferFromKeyframe(playerId: UUID) -> Bool
    func shouldContinueLoading(with parameters: LoadControlParams) -> Bool
    func shouldContinuePreloading(timeline: Timeline, mediaPeriodId: MediaPeriodId, bufferedDuration: CMTime) -> Bool
    func shouldStartPlayback(parameters: LoadControlParams) -> Bool
    /// The buffered duration at which ``shouldStartPlayback(parameters:)`` may answer differently, for the player to
    /// ask again then.
    func bufferedDurationToCheckPlayback(parameters: LoadControlParams) -> CMTime
}

public struct LoadControlParams {
    let playerId: UUID
    let timeline: Timeline
    let mediaPeriodId: MediaPeriodId
    let playbackPosition: CMTime
    let bufferedDuration: CMTime
    let playbackSpeed: Float
    let playWhenReady: Bool
    let rebuffering: Bool
    let targetLiveOffset: CMTime
    let lastRebufferRealtime: CMTime
}

/// The load control of one player, deciding when to start playing and when to load.
///
/// - Loading: up to a high water level of 50 s, or the preferred forward buffer duration, then not again until less
///   than the low water level of 20 s is buffered: the buffer refills in bursts, and the network is idle in between.
///   A full buffer pauses loading only if playback is likely to keep up; otherwise loading goes on.
/// - Playback of HLS starts with one target duration buffered, or a third of it when the predicted bandwidth is three
///   times what the stream needs. Low-latency streams start with their part hold-back.
/// - Progressive playback starts once the buffer and the measured transfer rate are likely to keep up with the media
///   to the end.
/// - After a stall the same rules apply: there is no separate rebuffer duration.
///
/// Each player needs its own load control.
final class DefaultLoadControl: LoadControl {
    let queue: Queue
    private let allocator: DefaultAllocator
    private let bandwidthMeter: BandwidthMeter?

    private let preferredForwardBufferDuration: CMTime
    private let backBufferDuration: CMTime
    private let retainBackBufferFromKeyframe: Bool
    private let targetBufferBytesOverwrite: Int?
    private let prioritizeTimeOverSizeThresholds: Bool

    private var playerId: UUID?
    private var isLoading = false
    /// Loading paused at the high water level: playback may start with a full buffer.
    private var isBufferFull = false
    private var targetBufferBytes = 0
    private var trackSelections: [SETrackSelection?] = []

    /// - Parameters:
    ///   - bandwidthMeter: Measures the network for the playback decisions. Without it playback starts as soon as
    ///     a little is buffered.
    ///   - preferredForwardBufferDuration: How much to buffer ahead. Zero for the default.
    init(
        queue: Queue,
        bandwidthMeter: BandwidthMeter? = nil,
        allocator: DefaultAllocator? = nil,
        preferredForwardBufferDuration: CMTime = .zero,
        backBufferDuration: CMTime = DefaultConstants.backBufferDuration,
        retainBackBufferFromKeyframe: Bool = DefaultConstants.retainBackBufferFromKeyframe,
        targetBufferBytes: Int? = nil,
        prioritizeTimeOverSizeThresholds: Bool = false
    ) {
        self.queue = queue
        self.bandwidthMeter = bandwidthMeter
        self.allocator = allocator ?? DefaultAllocator()
        self.preferredForwardBufferDuration = preferredForwardBufferDuration
        self.backBufferDuration = backBufferDuration
        self.retainBackBufferFromKeyframe = retainBackBufferFromKeyframe
        self.targetBufferBytesOverwrite = targetBufferBytes
        self.prioritizeTimeOverSizeThresholds = prioritizeTimeOverSizeThresholds
    }

    func onPrepared(playerId: UUID) {
        assertQueue()
        assert(self.playerId == nil || self.playerId == playerId, "Each player needs its own DefaultLoadControl")
        self.playerId = playerId
        resetLoadingState()
    }

    func onTracksSelected(
        parameters: LoadControlParams,
        trackGroups: TrackGroupArray,
        trackSelections: [SETrackSelection?]
    ) {
        assertQueue()
        self.trackSelections = trackSelections
        targetBufferBytes = targetBufferBytesOverwrite ?? calculateTargetBufferBytes(trackSelectionArray: trackSelections)
    }

    func onStopped(playerId: UUID) {
        assertQueue()
        resetLoadingState()
    }

    func onReleased(playerId: UUID) {
        assertQueue()
        resetLoadingState()
        self.playerId = nil
    }

    func getAllocator() -> Allocator {
        allocator
    }

    func getBackBufferDuration(playerId: UUID) -> CMTime {
        backBufferDuration
    }

    func getMinBufferDuration(playerId: UUID) -> CMTime {
        waterLevels().low
    }

    func getMaxBufferDuration(playerId: UUID) -> CMTime {
        waterLevels().high
    }

    func retainBackBufferFromKeyframe(playerId: UUID) -> Bool {
        retainBackBufferFromKeyframe
    }

    func shouldContinueLoading(with parameters: LoadControlParams) -> Bool {
        assertQueue()
        let levels = waterLevels()
        let targetBufferSizeReached = targetBufferBytes > 0 && allocator.totalBytesAllocated >= targetBufferBytes

        // Faster playback drains the buffer faster: the low level holds as much playback time.
        var low = levels.low
        if parameters.playbackSpeed > 1 {
            low = min(CMTimeMultiplyByFloat64(low, multiplier: Float64(parameters.playbackSpeed)), levels.high)
        }
        low = max(low, .from(microseconds: 500_000))

        let wasLoading = isLoading
        if parameters.bufferedDuration < low {
            isLoading = prioritizeTimeOverSizeThresholds || !targetBufferSizeReached
        } else if targetBufferSizeReached && !prioritizeTimeOverSizeThresholds {
            // Memory bounds the buffer whatever the network.
            isLoading = false
        } else if parameters.bufferedDuration >= levels.high {
            // A full buffer pauses loading only if playback would keep up: otherwise loading goes past the level.
            isLoading = !isLikelyToKeepUp(parameters)
        }

        if isLoading != wasLoading {
            SELogger.debug(.loadControl, "\(isLoading ? "Loading" : "Not loading"): buffered \(parameters.bufferedDuration.seconds)s, levels \(low.seconds)–\(levels.high.seconds)s, \(allocator.totalBytesAllocated >> 10) of \(targetBufferBytes >> 10) KiB")
        }
        isBufferFull = !isLoading
        return isLoading
    }

    func shouldStartPlayback(parameters: LoadControlParams) -> Bool {
        assertQueue()
        // A seek empties the buffer before loading is asked about again: only a buffer that is still full counts.
        if isBufferFull, parameters.bufferedDuration >= waterLevels().low {
            SELogger.debug(.loadControl, "Playback can start: the buffer is full, \(parameters.bufferedDuration.seconds)s")
            return true
        }
        // Nothing is left to load, as when all of the media is on storage: no transfer needs predicting.
        if let remaining = remainingDuration(parameters), parameters.bufferedDuration.seconds >= remaining - 0.01 {
            SELogger.debug(.loadControl, "Playback can start: buffered to the end, \(parameters.bufferedDuration.seconds)s")
            return true
        }
        if !prioritizeTimeOverSizeThresholds, targetBufferBytes > 0, allocator.totalBytesAllocated >= targetBufferBytes {
            SELogger.debug(.loadControl, "Playback can start: the memory for the buffer is used up, \(allocator.totalBytesAllocated / 1024) KB")
            return true
        }
        let keepsUp = isLikelyToKeepUp(parameters)
        SELogger.verbose(.loadControl, "Playback \(keepsUp ? "can start" : "waits"): buffered \(parameters.bufferedDuration.seconds)s, \(keepsUp ? "likely" : "not likely") to keep up")
        return keepsUp
    }

    func bufferedDurationToCheckPlayback(parameters: LoadControlParams) -> CMTime {
        assertQueue()
        let buffered = parameters.bufferedDuration.seconds
        let step = DefaultConstants.playbackCheckStep.seconds
        guard let manifest = window(of: parameters)?.manifest as? HlsManifest else {
            // The progressive prediction changes with every bit buffered: check again a little later.
            return CMTime(seconds: buffered + step, preferredTimescale: 1000)
        }

        let thresholds = HlsStartupThresholds(
            targetDuration: manifest.mediaPlaylist.targetDuration,
            serverControl: manifest.mediaPlaylist.serverControl,
            requiredBitrate: requiredBitrate(),
            rate: Double(max(abs(parameters.playbackSpeed), 1))
        )
        let liveCap = liveOffsetCap(parameters)
        let next = [thresholds.lowLatency, thresholds.fast, thresholds.normal]
            .compactMap { $0.map { min($0, liveCap) } }
            .filter { $0 > buffered }
            .min()
        // Past the fast threshold the bandwidth decides, and it changes over time.
        return CMTime(seconds: next ?? buffered + step, preferredTimescale: 1000)
    }

    func shouldContinuePreloading(
        timeline: Timeline,
        mediaPeriodId: MediaPeriodId,
        bufferedDuration: CMTime
    ) -> Bool {
        assertQueue()
        return !isLoading
    }

    // MARK: - Likely to keep up

    private func isLikelyToKeepUp(_ parameters: LoadControlParams) -> Bool {
        let window = window(of: parameters)
        if let manifest = window?.manifest as? HlsManifest {
            return isLikelyToKeepUp(parameters, playlist: manifest.mediaPlaylist)
        }
        return isLikelyToKeepUpProgressive(parameters, window: window)
    }

    /// Whether HLS playback is likely to keep up with what is buffered.
    private func isLikelyToKeepUp(_ parameters: LoadControlParams, playlist: HlsMediaPlaylist) -> Bool {
        let rate = Double(max(abs(parameters.playbackSpeed), 1))
        let buffered = parameters.bufferedDuration.seconds
        let thresholds = HlsStartupThresholds(
            targetDuration: playlist.targetDuration,
            serverControl: playlist.serverControl,
            requiredBitrate: requiredBitrate(),
            rate: rate
        )
        let liveCap = liveOffsetCap(parameters)

        if let lowLatency = thresholds.lowLatency, buffered >= min(lowLatency, liveCap) {
            return true
        }
        if buffered >= min(thresholds.normal, liveCap) {
            return true
        }
        guard buffered >= min(thresholds.fast, liveCap), thresholds.lowLatency == nil else {
            return false
        }

        // The prediction for a transfer the size of a segment.
        let segmentBytes = thresholds.normal * Double(thresholds.requiredBitrate) / 8
        guard thresholds.requiredBitrate > 0,
              let prediction = bandwidthMeter?.predict(
                  expectedTransferBytes: segmentBytes > 0 ? Int(segmentBytes) : nil,
                  algorithm: .standard
              ) else {
            return false
        }
        // The prediction as it is, without its safety margin: the headroom of the fast start allows for it.
        return Double(prediction.bitrate) >= thresholds.fastBitrate
    }

    /// Whether progressive playback is likely to keep up, with the media consuming the selected bitrate evenly.
    private func isLikelyToKeepUpProgressive(_ parameters: LoadControlParams, window: Window?) -> Bool {
        let isNetwork = window.map { !($0.mediaItem.localConfiguration?.url.isFileURL ?? false) } ?? true
        let demandBitrate = trackSelections.reduce(0) { total, selection in
            guard let format = selection?.selectedFormat else { return total }
            let bitrate = format.averageBitrate != Format.noValue ? format.averageBitrate : format.bitrate
            return bitrate != Format.noValue ? total + bitrate : total
        }
        let rates = bandwidthMeter?.transferRates()
        let bytesPerSecond = rates.map { $0.movingAverage > 0 ? $0.movingAverage : $0.average } ?? 0
        let buffered = parameters.bufferedDuration.seconds
        let liveCap = liveOffsetCap(parameters)

        // As much as the maximum starts playback whatever the network, measured or not: what is held on storage
        // needs none.
        if buffered >= min(Self.progressiveMaximumBuffer, liveCap) {
            return true
        }

        guard isNetwork, demandBitrate > 0, let rates, bytesPerSecond > 0,
              let duration = window?.duration, duration.isNumeric, duration > .zero else {
            // Nothing to predict with: local files and unknown bitrates start with a little buffered, and the network
            // with something measured.
            let hasMeasurement = !isNetwork || bytesPerSecond > 0 || bandwidthMeter == nil
            return hasMeasurement && buffered >= min(Self.bufferWithoutMeasurements, liveCap)
        }

        // The demand grows by how much the transfer rate varies.
        let variability = rates.average != 0 ? rates.standardDeviation / rates.average : 0
        let inflation = Float(1 + variability)
        let rate = Double(max(abs(parameters.playbackSpeed), 1))
        var profile = ProgressiveDemandProfile.constant(
            bytesPerSecond: Double(demandBitrate) / 8,
            duration: duration.seconds
        )
        var wait = 0.0
        return progressiveIsLikelyToKeepUp(
            currentTime: max(0, parameters.playbackPosition.seconds),
            playableDurationAhead: parameters.bufferedDuration.seconds,
            networkBytesPerSecond: bytesPerSecond / rate,
            demandInflation: inflation,
            profile: &profile,
            additionalWait: &wait
        )
    }

    /// The bandwidth of the selected variant, in bits per second. It covers all of its tracks, which repeat it, so
    /// it is the largest of their bitrates rather than their sum. A variant that doesn't tell it, as the one of a media
    /// playlist alone, has the bitrate of its loaded segments.
    private func requiredBitrate() -> Int {
        trackSelections.reduce(0) { required, selection in
            guard let selection else { return required }
            let declared = selection.selectedFormat.bitrate
            guard let bitrate = declared != Format.noValue ? declared : selection.measuredBitrate else {
                return required
            }
            return max(required, bitrate)
        }
    }

    /// Live playback can't buffer more than a part of its offset from the live edge.
    private func liveOffsetCap(_ parameters: LoadControlParams) -> Double {
        parameters.targetLiveOffset.isValid
            ? parameters.targetLiveOffset.seconds * Self.liveStartupOffsetFraction
            : .infinity
    }

    /// How much of the content is left to play, or `nil` for live content or an unknown duration.
    private func remainingDuration(_ parameters: LoadControlParams) -> Double? {
        guard let window = window(of: parameters), !window.isLive, window.duration.isNumeric else {
            return nil
        }
        return max(0, window.duration.seconds - parameters.playbackPosition.seconds)
    }

    private func window(of parameters: LoadControlParams) -> Window? {
        guard let periodIndex = parameters.timeline.indexOfPeriod(by: parameters.mediaPeriodId.periodId) else {
            return nil
        }
        let period = parameters.timeline.getPeriod(periodIndex: periodIndex, period: Period())
        return parameters.timeline.getWindow(windowIndex: period.windowIndex, window: Window())
    }

    // MARK: - Levels

    /// Loading stops at the high level, 50 s unless a preference says otherwise, and starts again below the low
    /// level, 20 s.
    private func waterLevels() -> (low: CMTime, high: CMTime) {
        let preferred = preferredForwardBufferDuration.isNumeric && preferredForwardBufferDuration > .zero
            ? max(1, Int(preferredForwardBufferDuration.seconds.rounded(.down)))
            : nil
        let high = preferred ?? Self.highWaterLevel
        let low = min(high, Self.lowWaterLevel)
        return (CMTime(value: CMTimeValue(low), timescale: 1), CMTime(value: CMTimeValue(high), timescale: 1))
    }

    private func calculateTargetBufferBytes(trackSelectionArray: [SETrackSelection?]) -> Int {
        let targetBufferSize = trackSelectionArray
            .compactMap { $0 }
            .reduce(0, { $0 + $1.trackGroup.type.defaultBufferSize(isLocalPlayback: false) /*TODO: check for local*/ })
        return max(.defaultMinBufferSize, targetBufferSize)
    }

    private func resetLoadingState() {
        targetBufferBytes = targetBufferBytesOverwrite ?? .defaultMinBufferSize
        isLoading = false
        isBufferFull = false
        trackSelections = []
    }

    private func assertQueue() {
        #if DEBUG
        if !queue.isCurrent() {
            assertionFailure("The load control must be used on the queue of its player")
        }
        #endif
    }
}

private extension DefaultLoadControl {
    /// How much is buffered ahead, in seconds.
    static let highWaterLevel = 50
    /// Below how much buffered loading starts again, in seconds.
    static let lowWaterLevel = 20
    /// As much buffered starts progressive playback whatever the network, in seconds.
    static let progressiveMaximumBuffer = 20.0
    /// How much starts playback when nothing predicts the network, in seconds.
    static let bufferWithoutMeasurements = 1.0
    /// The most of the offset from the live edge that playback waits to buffer before it starts.
    static let liveStartupOffsetFraction = 0.5
}

extension DefaultLoadControl {
    public enum DefaultConstants {
        public static let backBufferDuration: CMTime = .zero
        public static let retainBackBufferFromKeyframe: Bool = true
        /// How much more to buffer before asking again whether to start, when no threshold says.
        public static let playbackCheckStep: CMTime = CMTime(seconds: 0.5, preferredTimescale: 1000)
    }
}

/// The buffer HLS playback waits for: a target duration, or a third of it, and at least a second, when the bandwidth is
/// three times what the stream needs. In seconds and bits per second.
struct HlsStartupThresholds {
    static let maxTargetDuration = 15
    static let fastStartTargetDurations = 0.33
    static let fastStartMinimumBuffer = 1.0
    static let fastStartBandwidthMultiplier = 3.0

    /// Buffered duration that starts playback.
    let normal: Double
    /// Buffered duration that starts playback if the bandwidth allows.
    let fast: Double
    /// Bandwidth the fast start needs.
    let fastBitrate: Double
    /// Buffered duration that starts low-latency playback, or `nil` if the stream isn't low latency.
    let lowLatency: Double?
    let requiredBitrate: Int

    init(
        targetDuration: CMTime,
        serverControl: HlsMediaPlaylist.ServerControl,
        requiredBitrate: Int,
        rate: Double
    ) {
        // The target duration is an integer number of seconds.
        let seconds = targetDuration.isNumeric ? Int(targetDuration.seconds.rounded(.down)) : 0
        let target = Double(min(seconds, Self.maxTargetDuration))
        normal = target
        fast = min(normal, max(Self.fastStartMinimumBuffer, Self.fastStartTargetDurations * target))
        fastBitrate = Self.fastStartBandwidthMultiplier * Double(requiredBitrate) * rate
        self.requiredBitrate = requiredBitrate

        // Without part durations, the part hold-back alone: the specification makes it at least three parts.
        lowLatency = serverControl.canBlockReload && serverControl.partHoldBack.isNumeric
            ? serverControl.partHoldBack.seconds
            : nil
    }
}
private extension Int {
    static let defaultBufferSegmentSize: Int = 64 * 1024
    static let defaultVideoBufferSize: Int = 2000 * .defaultBufferSegmentSize
    static let defaultVideoBufferSizeForLocalPlayback: Int = 300 * .defaultBufferSegmentSize
    static let defaultAudioBufferSize: Int = 200 * .defaultBufferSegmentSize
    static let defaultTextBufferSize: Int = 2 * .defaultBufferSegmentSize
    static let defaultMetadataBufferSize: Int = 2 * .defaultBufferSegmentSize
    static let defaultCameraMotionBufferSize: Int = 2 * .defaultBufferSegmentSize
    static let defaultImageBufferSize: Int = 300 * .defaultBufferSegmentSize
    static let defaultMuxedBufferSize: Int = .defaultVideoBufferSize + .defaultAudioBufferSize + .defaultTextBufferSize
    static let defaultMinBufferSize: Int = 200 * .defaultBufferSegmentSize
}

private extension TrackType {
    func defaultBufferSize(isLocalPlayback: Bool) -> Int {
        switch self {
        case .default:
            .defaultMuxedBufferSize
        case .audio:
            .defaultAudioBufferSize
        case .video:
            isLocalPlayback ? .defaultVideoBufferSizeForLocalPlayback : .defaultVideoBufferSize
        case .text:
            .defaultTextBufferSize
        case .metadata:
            .defaultMetadataBufferSize
        case .cameraMotion:
            .defaultCameraMotionBufferSize
        case .image:
            .defaultImageBufferSize
        case .none:
            .zero
        case .unknown:
            .defaultMinBufferSize
        }
    }
}
