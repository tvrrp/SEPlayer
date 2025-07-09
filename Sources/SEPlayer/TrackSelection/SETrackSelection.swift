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
        var updatedGroups: [TrackGroup?] = Array(repeating: nil, count: rendererCapabilities.count)

        for (index, rendererCapability) in rendererCapabilities.enumerated() {
            for group in trackGroups {
                if rendererSupported(rendererCapability, group: group) {
                    updatedGroups[index] = group
                }
            }
        }

        let selections: [SETrackSelection?] = updatedGroups.map { trackGroup in
            if let trackGroup {
                return FixedTrackSelection(trackGroup: trackGroup)
            } else {
                return nil
            }
        }

        return TrackSelectionResult(
            renderersConfig: updatedGroups.map { _ in true },
            selections: selections,
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

    func rendererSupported(_ rendererCapability: RendererCapabilities, group: TrackGroup) -> Bool {
        for format in group.formats {
            if rendererCapability.supportsFormat(format) {
                return true
            }
        }

        return false
    }

    func supportsFormat(rendererCapabilities: RendererCapabilities, trackGroup: TrackGroup) -> [Bool] {
        trackGroup.formats.map { rendererCapabilities.supportsFormat($0) }
    }
}
