//
//  SETrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

import Foundation.NSUUID

public struct SETrackSelectionDefinition {
    public let group: TrackGroup
    public let tracks: [Int]
    public let type: TrackSelectionType

    public init(
        group: TrackGroup,
        tracks: [Int],
        type: TrackSelectionType = .unset
    ) {
        self.group = group
        self.tracks = tracks
        self.type = type
    }
}

@frozen public enum TrackSelectionReason {
    case unknown
    case initial
    case manual
    case adaptive
    case trickPlay
}

public protocol SETrackSelectionFactory {
    func createTrackSelections(
        definitions: [SETrackSelectionDefinition?],
        bandwidthMeter: BandwidthMeter,
        mediaPeriodId: MediaPeriodId,
        timeline: Timeline
    ) -> [SETrackSelection?]
}

public protocol SETrackSelection: TrackSelection {
    var selectedFormat: Format { get }
    var selectedIndexInTrackGroup: Int? { get }
    var selectedIndex: Int { get }
    var selectedReason: TrackSelectionReason { get }
    var selectionData: Any? { get }

    func enable()
    func disable()
    func playbackSpeedDidChange(_ playbackSpeed: Float)
    func onDiscontinuity()
    func onRebuffer()
    func playWhenReadyChanged(_ playWhenReady: Bool)

    // TODO: HLS
//    func updateSelectedTrack(
//        playbackPositionUs: Int64,
//        bufferedDurationUs: Int64,
//        availableDurationUs: Int64,
//        queue: [Void /*TODO: MediaChunk */],
//        mediaChunkIterators: [Void /*TODO: MediaChunkIterator */],
//    )
//    func evaluateQueueSize(playbackPositionUs: Int64, queue: [MediaChunk]) -> Int
//    func shouldCancelChunkLoad(playbackPositionUs: Int64, loadingChunk: Chunk, queue: [MediaChunk]) -> Int

    func excludeTrack(index: Int, exclusionDurationMs: Int64) -> Bool
    func isTrackExcluded(index: Int, nowMs: Int64) -> Bool
    func getLatestBitrateEstimate() -> Int64?

    func isEquals(to other: SETrackSelection) -> Bool
}

extension SETrackSelection {
    func onDiscontinuity() {}
    func onRebuffer() {}
    func playWhenReadyChanged(_ playWhenReady: Bool) {}

//    TODO: HLS
//    func shouldCancelChunkLoad(playbackPositionUs: Int64, loadingChunk: Chunk, queue: [MediaChunk]) -> Int {
//        false
//    }

    func getLatestBitrateEstimate() -> Int64? { nil }
}
