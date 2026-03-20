//
//  MaskingMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

import CoreMedia

final class MaskingMediaPeriod: MediaPeriod {
    protocol PrepareListener: AnyObject {
        func prepareCompleted(mediaPeriodId: MediaPeriodId)
        func prepareError(mediaPeriodId: MediaPeriodId, error: Error)
    }

    var trackGroups: TrackGroupArray { mediaPeriod?.trackGroups ?? .empty }
    var isLoading: Bool { mediaPeriod?.isLoading ?? false }

    weak var listener: PrepareListener?
    let id: MediaPeriodId
    var preparePositionOverride: CMTime

    let preparePosition: CMTime
    private let allocator: Allocator
    private weak var mediaSource: MediaSource?
    private var mediaPeriod: MediaPeriod?

    private var notifiedPrepareError = false
    private var callback: (any MediaPeriodCallback)?

    init(id: MediaPeriodId, allocator: Allocator, preparePosition: CMTime) {
        self.id = id
        self.allocator = allocator
        self.preparePosition = preparePosition
        preparePositionOverride = .invalid
    }

    func setMediaSource(_ mediaSource: MediaSource) {
        guard self.mediaSource == nil else { return }
        self.mediaSource = mediaSource
    }

    func createPeriod(id: MediaPeriodId) throws {
        guard let mediaSource else { return }

        let preparePosition = preparePositionWithOverride(preparePosition: preparePosition)
        mediaPeriod = try mediaSource.createPeriod(id: id, allocator: allocator, startPosition: preparePosition)
        if callback != nil {
            mediaPeriod?.prepare(callback: self, on: preparePosition)
        }
    }

    func releasePeriod() {
        if let mediaPeriod { mediaSource?.release(mediaPeriod: mediaPeriod) }
    }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        self.callback = callback
        mediaPeriod?.prepare(
            callback: self,
            on: preparePositionWithOverride(preparePosition: preparePosition)
        )
    }

    func maybeThrowPrepareError() throws {
        do {
            if let mediaPeriod {
                try mediaPeriod.maybeThrowPrepareError()
            } else if let mediaSource {
                try mediaSource.maybeThrowSourceInfoRefreshError()
            }
        } catch {
            guard let listener else {
                throw error
            }

            if !notifiedPrepareError {
                notifiedPrepareError = true
                listener.prepareError(mediaPeriodId: id, error: error)
            }
        }
    }

    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [TriggerableSampleStream?],
        streamResetFlags: inout [Bool],
        position: CMTime
    ) -> CMTime {
        let position = (preparePositionOverride.isValid && position == preparePosition)
            ? preparePositionOverride
            : position
        preparePositionOverride = .invalid
        return mediaPeriod?.selectTrack(
            selections: selections,
            mayRetainStreamFlags: mayRetainStreamFlags,
            streams: &streams,
            streamResetFlags: &streamResetFlags,
            position: position
        ) ?? .invalid
    }

    func discardBuffer(position: CMTime, toKeyframe: Bool) {
        mediaPeriod?.discardBuffer(position: position, toKeyframe: toKeyframe)
    }

    func readDiscontinuity() -> CMTime {
        mediaPeriod?.readDiscontinuity() ?? .invalid
    }

    func getBufferedPosition() -> CMTime {
        mediaPeriod?.getBufferedPosition() ?? .zero
    }

    func seek(position: CMTime) -> CMTime {
        mediaPeriod?.seek(position: position) ?? .zero
    }

    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        mediaPeriod?.getAdjustedSeekPosition(position: position, seekParameters: seekParameters) ?? position
    }

    func getNextLoadPosition() -> CMTime {
        mediaPeriod?.getNextLoadPosition() ?? .zero
    }

    func reevaluateBuffer(position: CMTime) {
        mediaPeriod?.reevaluateBuffer(position: position)
    }

    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
        mediaPeriod?.continueLoading(with: loadingInfo) ?? false
    }
}

extension MaskingMediaPeriod: MediaPeriodCallback {
    func didPrepare(mediaPeriod: any MediaPeriod) {
        callback?.didPrepare(mediaPeriod: self)
    }

    func continueLoadingRequested(with source: any MediaPeriod) {
        callback?.continueLoadingRequested(with: self)
    }
}

private extension MaskingMediaPeriod {
    func preparePositionWithOverride(preparePosition: CMTime) -> CMTime {
        !preparePositionOverride.isValid ? preparePositionOverride : preparePosition
    }
}
