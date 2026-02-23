//
//  LoadControl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.05.2025.
//

import Foundation.NSUUID

public protocol LoadControl {
    var queue: Queue { get }
    func onPrepared(playerId: UUID)
    func onTracksSelected(parameters: LoadControlParams, trackGroups: TrackGroupArray, trackSelections: [SETrackSelection?])
    func onStopped(playerId: UUID)
    func onReleased(playerId: UUID)
    func getAllocator() -> Allocator
    func getBackBufferDurationUs(playerId: UUID) -> Int64
    func retainBackBufferFromKeyframe(playerId: UUID) -> Bool
    func shouldContinueLoading(with parameters: LoadControlParams) -> Bool
    func shouldContinuePreloading(timeline: Timeline, mediaPeriodId: MediaPeriodId, bufferedDurationUs: Int64) -> Bool
    func shouldStartPlayback(parameters: LoadControlParams) -> Bool
}

public struct LoadControlParams {
    let playerId: UUID
    let timeline: Timeline
    let mediaPeriodId: MediaPeriodId
    let playbackPositionUs: Int64
    let bufferedDurationUs: Int64
    let playbackSpeed: Float
    let playWhenReady: Bool
    let rebuffering: Bool
    let targetLiveOffsetUs: Int64
    let lastRebufferRealtimeMs: Int64
}

final class DefaultLoadControl: LoadControl {
    let queue: Queue
    private let allocator: DefaultAllocator

    private let minBufferUs: Int64
    private let maxBufferUs: Int64
    private let bufferForPlaybackUs: Int64
    private let bufferForPlaybackAfterRebufferUs: Int64
    private let targetBufferBytesOverwrite: Int?
    private let prioritizeTimeOverSizeThresholds: Bool
    private let backBufferDurationUs: Int64
    private let retainBackBufferFromKeyframe: Bool

    private var loadingStates: [UUID: PlayerLoadingState] = [:]

    init(
        queue: Queue,
        allocator: DefaultAllocator? = nil,
        minBufferMs: Int64 = DefaultConstants.minBufferMs,
        maxBufferMs: Int64 = DefaultConstants.maxBufferMs,
        bufferForPlaybackMs: Int64 = DefaultConstants.bufferForPlaybackMs,
        bufferForPlaybackAfterRebufferMs: Int64 = DefaultConstants.bufferForPlaybackAfterRebuffer,
        targetBufferBytes: Int? = nil,
        prioritizeTimeOverSizeThresholds: Bool = false,
        backBufferDurationMs: Int64 = DefaultConstants.backBufferDurationMs,
        retainBackBufferFromKeyframe: Bool = DefaultConstants.retainBackBufferFromKeyframe
    ) {
        self.queue = queue
        self.allocator = allocator ?? DefaultAllocator(individualAllocationSize: .defaultBufferSegmentSize)

        self.minBufferUs = Time.msToUs(timeMs: minBufferMs)
        self.maxBufferUs = Time.msToUs(timeMs: maxBufferMs)
        self.bufferForPlaybackUs = Time.msToUs(timeMs: bufferForPlaybackMs)
        self.bufferForPlaybackAfterRebufferUs = Time.msToUs(timeMs: bufferForPlaybackAfterRebufferMs)
        self.targetBufferBytesOverwrite = targetBufferBytes
        self.prioritizeTimeOverSizeThresholds = prioritizeTimeOverSizeThresholds
        self.backBufferDurationUs = Time.msToUs(timeMs: backBufferDurationMs)
        self.retainBackBufferFromKeyframe = retainBackBufferFromKeyframe
    }

    func onPrepared(playerId: UUID) {
        assertQueue()
        if loadingStates[playerId] == nil {
            loadingStates[playerId] = PlayerLoadingState()
        }
        resetLoadingState(for: playerId)
    }

    func onTracksSelected(
        parameters: LoadControlParams,
        trackGroups: TrackGroupArray,
        trackSelections: [SETrackSelection?]
    ) {
        assertQueue()
        assert(loadingStates[parameters.playerId] != nil)
        loadingStates[parameters.playerId]?.targetBufferBytes = targetBufferBytesOverwrite
            ?? calculateTargetBufferBytes(trackSelectionArray: trackSelections)
        updateAllocator()
    }

    func onStopped(playerId: UUID) {
        assertQueue()
        removePlayer(for: playerId)
    }

    func onReleased(playerId: UUID) {
        assertQueue()
        removePlayer(for: playerId)
    }

    func getAllocator() -> Allocator {
        assertQueue()
        return allocator
    }

    func getBackBufferDurationUs(playerId: UUID) -> Int64 {
        return backBufferDurationUs
    }

    func retainBackBufferFromKeyframe(playerId: UUID) -> Bool {
        return retainBackBufferFromKeyframe
    }

    func shouldContinueLoading(with parameters: LoadControlParams) -> Bool {
        assertQueue(); assert(loadingStates[parameters.playerId] != nil)
        let targetBufferSizeReached = allocator.totalBytesAllocated >= totalTargetBufferBytes()
        var minBufferUs = minBufferUs

        if parameters.playbackSpeed > 1 {
            let mediaDurationMinBufferUs = AudioUtils.mediaDurationFor(
                playoutDuration: minBufferUs,
                speed: parameters.playbackSpeed
            )
            minBufferUs = min(mediaDurationMinBufferUs, maxBufferUs)
        }

        minBufferUs = max(minBufferUs, 500_000)
        if parameters.bufferedDurationUs < minBufferUs {
            loadingStates[parameters.playerId]?.isLoading = prioritizeTimeOverSizeThresholds || !targetBufferSizeReached
        } else if parameters.bufferedDurationUs >= maxBufferUs || targetBufferSizeReached {
            loadingStates[parameters.playerId]?.isLoading = false
        }

        return loadingStates[parameters.playerId]?.isLoading ?? false
    }

    func shouldStartPlayback(parameters: LoadControlParams) -> Bool {
        assertQueue()
        let bufferedDurationUs = AudioUtils.mediaDurationFor(
            playoutDuration: parameters.bufferedDurationUs,
            speed: parameters.playbackSpeed
        )

        var minBufferDurationUs = parameters.rebuffering ? bufferForPlaybackAfterRebufferUs : bufferForPlaybackUs
        if parameters.targetLiveOffsetUs != .timeUnset {
            minBufferDurationUs = min(parameters.targetLiveOffsetUs / 2, minBufferDurationUs)
        }

        return minBufferDurationUs <= 0
            || bufferedDurationUs >= minBufferDurationUs
            || (!prioritizeTimeOverSizeThresholds && allocator.totalBytesAllocated >= totalTargetBufferBytes())
    }

    func shouldContinuePreloading(
        timeline: Timeline,
        mediaPeriodId: MediaPeriodId,
        bufferedDurationUs: Int64
    ) -> Bool {
        assertQueue()
        return loadingStates.values.first(where: { $0.isLoading == true }) == nil
    }

    private func calculateTargetBufferBytes(trackSelectionArray: [SETrackSelection?]) -> Int {
        let targetBufferSize = trackSelectionArray
            .compactMap { $0 }
            .reduce(0, { $0 + $1.trackGroup.type.defaultBufferSize(isLocalPlayback: false) /*TODO: check for local*/ })
        return max(.defaultMinBufferSize, targetBufferSize)
    }

    private func totalTargetBufferBytes() -> Int {
        loadingStates.values.reduce(0, { $0 + $1.targetBufferBytes })
    }

    private func resetLoadingState(for playerId: UUID) {
        assert(loadingStates[playerId] != nil)
        loadingStates[playerId]?.targetBufferBytes = targetBufferBytesOverwrite ?? .defaultMinBufferSize
        loadingStates[playerId]?.isLoading = false
    }

    private func removePlayer(for playerId: UUID) {
        if loadingStates.removeValue(forKey: playerId) != nil {
            updateAllocator()
        }
    }

    private func updateAllocator() {
        if loadingStates.isEmpty {
            allocator.reset()
        } else {
            allocator.setTargetBufferSize(new: totalTargetBufferBytes())
        }
    }

    private func assertQueue() {
        #if DEBUG
        if !queue.isCurrent() {
            assertionFailure("Players that share the same LoadControl must also share the same WorkQueue")
        }
        #endif
    }
}

extension DefaultLoadControl {
    public enum DefaultConstants {
        public static let minBufferMs: Int64 = 20000
        public static let maxBufferMs: Int64 = 50000
        public static let bufferForPlaybackMs: Int64 = 5000
        public static let bufferForPlaybackAfterRebuffer: Int64 = 10000
        public static let backBufferDurationMs: Int64 = .zero
        public static let retainBackBufferFromKeyframe: Bool = true
    }

    private struct PlayerLoadingState {
        var isLoading: Bool = false
        var targetBufferBytes: Int = 0
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
