//
//  SETrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

import CoreMedia.CMFormatDescription

public protocol SETrackSelection: TrackSelection {
    var id: UUID { get }
    var selectedReason: TrackSelectionReason { get }
    var selectedFormat: CMFormatDescription { get }
    var selectedIndex: Int { get }

    func enable()
    func disable()
    func playWhenReadyChanged(new playWhenReady: Bool)
}

extension SETrackSelection {
    func enable() {}
    func disable() {}
    func playWhenReadyChanged(new playWhenReady: Bool) {}
}

public enum TrackSelectionReason {
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
    ) throws -> TrackSelectionResult
}

struct DefaultTrackSelector: TrackSelector {
    func selectTracks(
        rendererCapabilities: [RendererCapabilities],
        trackGroups: [TrackGroup],
        periodId: MediaPeriodId,
        timeline: Timeline
    ) -> TrackSelectionResult {
        let updatedGroups: [TrackGroup] = trackGroups.map { group -> (Int, TrackGroup)? in
            if let index = findRenderer(rendererCapabilities: rendererCapabilities, group: group) {
                return (index, group)
            }
            return nil
        }
        .compactMap { $0 }
        .sorted(by: { $0.0 < $1.0 })
        .map { $0.1 }

        return TrackSelectionResult(
            renderersConfig: updatedGroups.map { _ in true },
            selections: updatedGroups.map { FixedTrackSelection(trackGroup: $0) },
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
