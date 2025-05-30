//
//  MaskingMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

final class MaskingMediaPeriod: MediaPeriod {
    protocol PrepareListener: AnyObject {
        func prepareCompleted(mediaPeriodId: MediaPeriodId)
        func prepareError(mediaPeriodId: MediaPeriodId, error: Error)
    }

    var trackGroups: [TrackGroup] { mediaPeriod?.trackGroups ?? [] }
    var isLoading: Bool { mediaPeriod?.isLoading ?? false }

    weak var listener: PrepareListener?
    let id: MediaPeriodId
    var preparePositionOverrideUs: Int64
    
    let preparePositionUs: Int64
    private let allocator: Allocator
    private weak var mediaSource: MediaSource?
    private var mediaPeriod: MediaPeriod?

    private var callback: (any MediaPeriodCallback)?

    init(id: MediaPeriodId, allocator: Allocator, preparePositionUs: Int64) {
        self.id = id
        self.allocator = allocator
        self.preparePositionUs = preparePositionUs
        preparePositionOverrideUs = .timeUnset
    }

    func setMediaSource(_ mediaSource: MediaSource) {
        guard self.mediaSource == nil else { return }
        self.mediaSource = mediaSource
    }

    func createPeriod(id: MediaPeriodId) {
        guard let mediaSource else { return }

        let preparePositionUs = preparePositionWithOverride(preparePositionUs: preparePositionUs)
        mediaPeriod = mediaSource.createPeriod(id: id, allocator: allocator, startPosition: preparePositionUs)
        if callback != nil {
            mediaPeriod?.prepare(callback: self, on: preparePositionUs)
        }
    }

    func releasePeriod() {
        if let mediaPeriod { mediaSource?.release(mediaPeriod: mediaPeriod) }
    }

    func prepare(callback: any MediaPeriodCallback, on time: Int64) {
        self.callback = callback
        mediaPeriod?.prepare(
            callback: self,
            on: preparePositionWithOverride(preparePositionUs: preparePositionUs)
        )
    }

    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        positionUs: Int64
    ) -> Int64 {
        let positionUs = (preparePositionOverrideUs != .timeUnset && positionUs == preparePositionUs)
            ? preparePositionOverrideUs
            : positionUs
        preparePositionOverrideUs = .timeUnset
        return mediaPeriod?.selectTrack(
            selections: selections,
            mayRetainStreamFlags: mayRetainStreamFlags,
            streams: &streams,
            streamResetFlags: &streamResetFlags,
            positionUs: positionUs
        ) ?? .timeUnset
    }

    func discardBuffer(to position: Int64, toKeyframe: Bool) {
        mediaPeriod?.discardBuffer(to: position, toKeyframe: toKeyframe)
    }

    func readDiscontinuity() -> Int64 {
        mediaPeriod?.readDiscontinuity() ?? .timeUnset
    }

    func getBufferedPositionUs() -> Int64 {
        mediaPeriod?.getBufferedPositionUs() ?? .zero
    }

    func seek(to position: Int64) -> Int64 {
        mediaPeriod?.seek(to: position) ?? .zero
    }

    func getAdjustedSeekPositionUs(positionUs: Int64, seekParameters: SeekParameters) -> Int64 {
        mediaPeriod?.getAdjustedSeekPositionUs(positionUs: positionUs, seekParameters: seekParameters) ?? positionUs
    }

    func getNextLoadPositionUs() -> Int64 {
        mediaPeriod?.getNextLoadPositionUs() ?? .zero
    }

    func reevaluateBuffer(positionUs: Int64) {
        mediaPeriod?.reevaluateBuffer(positionUs: positionUs)
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
    func preparePositionWithOverride(preparePositionUs: Int64) -> Int64 {
        preparePositionOverrideUs != .timeUnset ? preparePositionOverrideUs : preparePositionUs
    }
}
