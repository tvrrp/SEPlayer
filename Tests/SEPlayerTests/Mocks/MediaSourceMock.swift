//
//  MediaSourceMock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import CoreMedia
import DataSource
import Foundation
@testable import SEPlayer

// @AnyMockable()
// class MediaSourceMock2: MediaSource {
//    var isSingleWindow: Bool = false
//    func getMediaItem() -> MediaItem {}
//    func getInitialTimeline() -> Timeline? {}
//    func canUpdateMediaItem(new item: MediaItem) -> Bool {}
//    func updateMediaItem(new item: MediaItem) throws {}
//    func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID) throws {}
//    func enable(delegate: MediaSourceDelegate) {}
//    func createPeriod(
//        id: MediaPeriodId,
//        allocator: Allocator,
//        startPosition: Int64
//    ) throws -> MediaPeriod {}
//    func release(mediaPeriod: MediaPeriod) {}
//    func disable(delegate: MediaSourceDelegate) {}
//    func releaseSource(delegate: MediaSourceDelegate) {}
//    func continueLoadingRequested(with source: any MediaSource) {}
// }

class MediaSourceMock: MediaSource {
    func maybeThrowSourceInfoRefreshError() throws {
        // TODO:
    }

    let isSingleWindow = true
    var methodInvocationStorage = [String: Int]()

    private let mediaItem: MediaItem

    init(mediaItem: MediaItem) {
        self.mediaItem = mediaItem
    }

    func getMediaItem() -> MediaItem { mediaItem }
    func getInitialTimeline() -> Timeline? { nil }
    func canUpdateMediaItem(new item: MediaItem) -> Bool { false }
    func updateMediaItem(new item: MediaItem) {}
    func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID) throws {
        updateCounter()
    }

    func enable(delegate: MediaSourceDelegate) {}
    func createPeriod(id: MediaPeriodId, allocator: Allocator, startPosition: CMTime) throws -> MediaPeriod { MediaPeriodMock() }
    func release(mediaPeriod: MediaPeriod) {}
    func disable(delegate: MediaSourceDelegate) {}
    func releaseSource(delegate: MediaSourceDelegate) {
        updateCounter()
    }

    private func updateCounter(funcName: String = #function) {
        if var counter = methodInvocationStorage[funcName] {
            counter += 1
            methodInvocationStorage[funcName] = counter
        } else {
            methodInvocationStorage[funcName] = 1
        }
    }
}

class MediaPeriodMock: MediaPeriod {
    let trackGroups = TrackGroupArray.empty
    let isLoading: Bool = false

    func maybeThrowPrepareError() throws {}
    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {}
    func discardBuffer(position: CMTime, toKeyframe: Bool) {}
    func readDiscontinuity() -> CMTime { .invalid }
    func seek(position: CMTime) -> CMTime { .zero }
    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime { .zero }
    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        position: CMTime
    ) -> CMTime { .zero }
    func getBufferedPosition() -> CMTime { .zero }
    func getNextLoadPosition() -> CMTime { .zero }
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool { false }
    func stopLoading() {}
}
