//
//  SETrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

import CoreMedia
import VideoToolbox

protocol SETrackSelection: TrackSelection {
    var id: UUID { get }
    var selectedReason: TrackSelectionReason { get }
    var selectedFormat: CMFormatDescription { get }
    var selectedIndex: Int { get }
}

enum TrackSelectionReason {
    case unknown
    case initial
    case manual
    case adaptive
    case trickPlay
}

protocol TrackSelector {
    func selectTracks(
        rendererCapabilities: [RendererCapabilities],
        trackGroups: [TrackGroup],
        periodId: MediaPeriodId,
        timeline: Timeline
    ) -> TrackSelectionResult
}

struct DefaultTrackSelector: TrackSelector {
    func selectTracks(
        rendererCapabilities: [RendererCapabilities],
        trackGroups: [TrackGroup],
        periodId: MediaPeriodId,
        timeline: Timeline
    ) -> TrackSelectionResult {
        let updatedGroups: [TrackGroup?] = trackGroups.compactMap { group in
            if findRenderer(rendererCapabilities: rendererCapabilities, group: group) != nil {
                return group
            }
            return nil
        }

        return TrackSelectionResult(
            selections: updatedGroups.map { group in
                if let group {
                    return FixedTrackSelection(trackGroup: group)
                }
                return nil
            },
            tracks: Tracks.empty
        )
    }

    func findRenderer(rendererCapabilities: [RendererCapabilities], group: TrackGroup) -> Int? {
        for format in group.formats {
            for (index, rendererCapability) in rendererCapabilities.enumerated() {
                if rendererCapability.supportsFormat(format) {
                    return index
                }
            }
        }

        return nil
    }

    func supportsFormat(rendererCapabilities: RendererCapabilities, trackGroup: TrackGroup) -> [Bool] {
        trackGroup.formats.map { rendererCapabilities.supportsFormat($0) }
    }
}
