//
//  MaskingMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

import CoreMedia
import SEPlayerCommon

final class MaskingMediaPeriod: MediaPeriod {
    protocol PrepareListener: AnyObject {
        func prepareCompleted(mediaPeriodId: MediaPeriodId)
        func prepareError(mediaPeriodId: MediaPeriodId, error: Error)
    }

    var trackGroups: TrackGroupArray {
        let mediaPeriod = lock.withLock { mediaPeriod }
        return mediaPeriod?.trackGroups ?? .empty
    }

    var isLoading: Bool {
        let mediaPeriod = lock.withLock { mediaPeriod }
        return mediaPeriod?.isLoading ?? false
    }

    weak var listener: PrepareListener?
    let id: MediaPeriodId
    var preparePositionOverride: CMTime

    let preparePosition: CMTime
    private let allocator: Allocator
    private weak var mediaSource: MediaSource?
    private var mediaPeriod: MediaPeriod?

    private var notifiedPrepareError = false
    private var callback: (any MediaPeriodCallback)?

    private let lock = UnfairLock()

    init(id: MediaPeriodId, allocator: Allocator, preparePosition: CMTime) {
        self.id = id
        self.allocator = allocator
        self.preparePosition = preparePosition
        preparePositionOverride = .invalid
    }

    func setMediaSource(_ mediaSource: MediaSource) {
        lock.withLock {
            guard self.mediaSource == nil else { return }
            self.mediaSource = mediaSource
        }
    }

    func createPeriod(id: MediaPeriodId) throws {
        lock.lock()
        guard let mediaSource else {
            lock.unlock(); return
        }

        let preparePosition = preparePositionWithOverrideLocked(preparePosition: preparePosition)
        let callback = callback
        lock.unlock()

        let mediaPeriod = try mediaSource.createPeriod(id: id, allocator: allocator, startPosition: preparePosition)
        if callback != nil {
            mediaPeriod.prepare(callback: self, on: preparePosition)
        }

        lock.withLock { self.mediaPeriod = mediaPeriod }
    }

    func releasePeriod() {
        let (mediaPeriod, mediaSource) = lock.withLock { (mediaPeriod, mediaSource) }
        if let mediaPeriod {
            mediaSource?.release(mediaPeriod: mediaPeriod)
        }
    }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        lock.lock()
        self.callback = callback
        let preparePosition = preparePositionWithOverrideLocked(preparePosition: preparePosition)
        let mediaPeriod = mediaPeriod
        lock.unlock()

        mediaPeriod?.prepare(callback: self, on: preparePosition)
    }

    func maybeThrowPrepareError() throws {
        let (mediaPeriod, mediaSource) = lock.withLock { (mediaPeriod, mediaSource) }
        do {
            if let mediaPeriod {
                try mediaPeriod.maybeThrowPrepareError()
            } else if let mediaSource {
                try mediaSource.maybeThrowSourceInfoRefreshError()
            }
        } catch {
            lock.lock()
            guard let listener else {
                lock.unlock(); throw error
            }

            if !notifiedPrepareError {
                notifiedPrepareError = true
                lock.unlock()
                listener.prepareError(mediaPeriodId: id, error: error)
            }
        }
    }

    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        position: CMTime
    ) throws -> CMTime {
        lock.lock()
        let position = (preparePositionOverride.isValid && position == preparePosition)
            ? preparePositionOverride
            : position
        preparePositionOverride = .invalid
        let mediaPeriod = mediaPeriod
        lock.unlock()

        return try mediaPeriod?.selectTrack(
            selections: selections,
            mayRetainStreamFlags: mayRetainStreamFlags,
            streams: &streams,
            streamResetFlags: &streamResetFlags,
            position: position
        ) ?? .invalid
    }

    func discardBuffer(position: CMTime, toKeyframe: Bool) throws {
        let mediaPeriod = lock.withLock { mediaPeriod }
        try mediaPeriod?.discardBuffer(
            position: position,
            toKeyframe: toKeyframe
        )
    }

    func readDiscontinuity() -> CMTime {
        let mediaPeriod = lock.withLock { mediaPeriod }
        return mediaPeriod?.readDiscontinuity() ?? .invalid
    }

    func getBufferedPosition() -> CMTime {
        let mediaPeriod = lock.withLock { mediaPeriod }
        return mediaPeriod?.getBufferedPosition() ?? .zero
    }

    func seek(position: CMTime) throws -> CMTime {
        let mediaPeriod = lock.withLock { mediaPeriod }
        return try mediaPeriod?.seek(position: position) ?? .zero
    }

    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        let mediaPeriod = lock.withLock { mediaPeriod }
        return mediaPeriod?.getAdjustedSeekPosition(
            position: position,
            seekParameters: seekParameters
        ) ?? position
    }

    func getNextLoadPosition() -> CMTime {
        let mediaPeriod = lock.withLock { mediaPeriod }
        return mediaPeriod?.getNextLoadPosition() ?? .zero
    }

    func reevaluateBuffer(position: CMTime) {
        let mediaPeriod = lock.withLock { mediaPeriod }
        mediaPeriod?.reevaluateBuffer(position: position)
    }

    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
        let mediaPeriod = lock.withLock { mediaPeriod }
        return mediaPeriod?.continueLoading(with: loadingInfo) ?? false
    }

    func stopLoading() {
        let mediaPeriod = lock.withLock { mediaPeriod }
        mediaPeriod?.stopLoading()
    }
}

extension MaskingMediaPeriod: MediaPeriodCallback {
    func didPrepare(mediaPeriod: any MediaPeriod) {
        let callback = lock.withLock { callback }
        callback?.didPrepare(mediaPeriod: self)
    }

    func continueLoadingRequested(with source: any MediaPeriod) {
        let callback = lock.withLock { callback }
        callback?.continueLoadingRequested(with: self)
    }
}

private extension MaskingMediaPeriod {
    func preparePositionWithOverrideLocked(preparePosition: CMTime) -> CMTime {
        !preparePositionOverride.isValid ? preparePositionOverride : preparePosition
    }
}
