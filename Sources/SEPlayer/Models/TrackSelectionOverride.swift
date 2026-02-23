//
//  TrackSelectionOverride.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//

public struct TrackSelectionOverride: Hashable {
    public var type: TrackType { mediaTrackGroup.type }
    public let mediaTrackGroup: TrackGroup
    public let trackIndices: [Int]

    public init(mediaTrackGroup: TrackGroup, trackIndex: Int) throws {
        try self.init(mediaTrackGroup: mediaTrackGroup, trackIndices: [trackIndex])
    }

    public init(mediaTrackGroup: TrackGroup, trackIndices: [Int]) throws {
        if !trackIndices.isEmpty, let min = trackIndices.min(), let max = trackIndices.max() {
            if min < 0 || max >= mediaTrackGroup.count {
                throw ErrorBuilder(errorDescription: "out of bounds") // TODO: real error
            }
        }

        self.mediaTrackGroup = mediaTrackGroup
        self.trackIndices = trackIndices
    }
}
