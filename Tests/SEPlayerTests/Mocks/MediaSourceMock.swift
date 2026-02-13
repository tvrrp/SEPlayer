//
//  MediaSourceMock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import Foundation
@testable import SEPlayer

//@AnyMockable()
//class MediaSourceMock2: MediaSource {
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
//}

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
    func createPeriod(id: MediaPeriodId, allocator: Allocator, startPosition: Int64) throws -> MediaPeriod { MediaPeriodMock() }
    func release(mediaPeriod: MediaPeriod) {}
    func disable(delegate: MediaSourceDelegate) {}
    func releaseSource(delegate: MediaSourceDelegate) {
        updateCounter()
    }
    func continueLoadingRequested(with source: MediaSource) {}

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
    func maybeThrowPrepareError() throws {
        // TODO: 
    }
    
    let trackGroups = [TrackGroup]()
    let isLoading: Bool = false

    func prepare(callback: any MediaPeriodCallback, on time: Int64) {}
    func discardBuffer(to position: Int64, toKeyframe: Bool) {}
    func readDiscontinuity() -> Int64 { .zero }
    func seek(to position: Int64) -> Int64 { .zero }
    func getAdjustedSeekPositionUs(positionUs: Int64, seekParameters: SeekParameters) -> Int64 { .zero }
    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        positionUs: Int64
    ) -> Int64 { .zero }
    func getBufferedPositionUs() -> Int64 { .zero }
    func getNextLoadPositionUs() -> Int64 { .zero }
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool { false }
}
