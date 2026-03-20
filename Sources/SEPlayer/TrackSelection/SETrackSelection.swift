//
//  SETrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

import CoreMedia
import Foundation.NSUUID
import SEPlayerCommon

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

    func updateSelectedTrack(
        playbackPosition: CMTime,
        bufferedDuration: CMTime,
        availableDuration: CMTime,
        queue: [MediaChunk],
        mediaChunkIterators: [MediaChunkIterator],
    )
    func evaluateQueueSize(playbackPosition: CMTime, queue: [MediaChunk]) -> Int
    func shouldCancelChunkLoad(playbackPosition: CMTime, loadingChunk: Chunk, queue: [MediaChunk]) -> Bool

    func excludeTrack(index: Int, exclusionDuration: CMTime) -> Bool
    func isTrackExcluded(index: Int, now: CMTime) -> Bool
    func getLatestBitrateEstimate() -> Int64?

    func isEquals(to other: SETrackSelection) -> Bool
}

extension SETrackSelection {
    func onDiscontinuity() {}
    func onRebuffer() {}
    func playWhenReadyChanged(_ playWhenReady: Bool) {}

    func shouldCancelChunkLoad(playbackPosition: CMTime, loadingChunk: Chunk, queue: [MediaChunk]) -> Bool {
        false
    }

    func getLatestBitrateEstimate() -> Int64? { nil }
}
