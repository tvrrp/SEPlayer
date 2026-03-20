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
    func retainBackBufferFromKeyframe(playerId: UUID) -> Bool
    func shouldContinueLoading(with parameters: LoadControlParams) -> Bool
    func shouldContinuePreloading(timeline: Timeline, mediaPeriodId: MediaPeriodId, bufferedDuration: CMTime) -> Bool
    func shouldStartPlayback(parameters: LoadControlParams) -> Bool
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

final class DefaultLoadControl: LoadControl {
    let queue: Queue
    private let allocator: DefaultAllocator

    private let minBuffer: CMTime
    private let maxBuffer: CMTime
    private let bufferForPlayback: CMTime
    private let bufferForPlaybackAfterRebuffer: CMTime
    private let targetBufferBytesOverwrite: Int?
    private let prioritizeTimeOverSizeThresholds: Bool
    private let backBufferDuration: CMTime
    private let retainBackBufferFromKeyframe: Bool

    private var loadingStates: [UUID: PlayerLoadingState] = [:]

    init(
        queue: Queue,
        allocator: DefaultAllocator? = nil,
        minBuffer: CMTime = DefaultConstants.minBuffer,
        maxBuffer: CMTime = DefaultConstants.maxBuffer,
        bufferForPlayback: CMTime = DefaultConstants.bufferForPlayback,
        bufferForPlaybackAfterRebuffer: CMTime = DefaultConstants.bufferForPlaybackAfterRebuffer,
        targetBufferBytes: Int? = nil,
        prioritizeTimeOverSizeThresholds: Bool = false,
        backBufferDuration: CMTime = DefaultConstants.backBufferDuration,
        retainBackBufferFromKeyframe: Bool = DefaultConstants.retainBackBufferFromKeyframe
    ) {
        self.queue = queue
        self.allocator = allocator ?? DefaultAllocator(individualAllocationSize: .defaultBufferSegmentSize)

        self.minBuffer = minBuffer
        self.maxBuffer = maxBuffer
        self.bufferForPlayback = bufferForPlayback
        self.bufferForPlaybackAfterRebuffer = bufferForPlaybackAfterRebuffer
        self.targetBufferBytesOverwrite = targetBufferBytes
        self.prioritizeTimeOverSizeThresholds = prioritizeTimeOverSizeThresholds
        self.backBufferDuration = backBufferDuration
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

    func getBackBufferDuration(playerId: UUID) -> CMTime {
        return backBufferDuration
    }

    func retainBackBufferFromKeyframe(playerId: UUID) -> Bool {
        return retainBackBufferFromKeyframe
    }

    func shouldContinueLoading(with parameters: LoadControlParams) -> Bool {
        assertQueue(); assert(loadingStates[parameters.playerId] != nil)
        let targetBufferSizeReached = allocator.totalBytesAllocated >= totalTargetBufferBytes()
        var minBuffer = minBuffer

        if parameters.playbackSpeed > 1 {
            let mediaDurationMinBuffer = CMTimeMultiplyByFloat64(
                minBuffer,
                multiplier: Float64(parameters.playbackSpeed)
            )
            minBuffer = min(mediaDurationMinBuffer, maxBuffer)
        }

        minBuffer = max(minBuffer, .from(microseconds: 500_000))
        if parameters.bufferedDuration < minBuffer {
            loadingStates[parameters.playerId]?.isLoading = prioritizeTimeOverSizeThresholds || !targetBufferSizeReached
        } else if parameters.bufferedDuration >= maxBuffer || targetBufferSizeReached {
            loadingStates[parameters.playerId]?.isLoading = false
        }

        return loadingStates[parameters.playerId]?.isLoading ?? false
    }

    func shouldStartPlayback(parameters: LoadControlParams) -> Bool {
        assertQueue()
        let bufferedDuration = CMTimeMultiplyByFloat64(
            parameters.bufferedDuration,
            multiplier: Float64(parameters.playbackSpeed)
        )

        var minBufferDuration = parameters.rebuffering ? bufferForPlaybackAfterRebuffer : bufferForPlayback
        if parameters.targetLiveOffset.isValid {
            minBufferDuration = min(CMTimeMultiplyByFloat64(parameters.targetLiveOffset, multiplier: 0.5), minBufferDuration)
        }

        return minBufferDuration <= .zero
            || bufferedDuration >= minBufferDuration
            || (!prioritizeTimeOverSizeThresholds && allocator.totalBytesAllocated >= totalTargetBufferBytes())
    }

    func shouldContinuePreloading(
        timeline: Timeline,
        mediaPeriodId: MediaPeriodId,
        bufferedDuration: CMTime
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
        public static let minBuffer: CMTime = CMTime(seconds: 20, preferredTimescale: 1000)
        public static let maxBuffer: CMTime = CMTime(seconds: 50, preferredTimescale: 1000)
        public static let bufferForPlayback: CMTime = CMTime(seconds: 5, preferredTimescale: 1000)
        public static let bufferForPlaybackAfterRebuffer: CMTime = CMTime(seconds: 10, preferredTimescale: 1000)
        public static let backBufferDuration: CMTime = .zero
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
