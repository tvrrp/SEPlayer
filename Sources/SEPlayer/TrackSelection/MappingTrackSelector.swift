//
//  MappingTrackSelector.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 09.06.2025.
//

protocol MappingTrackSelector: TrackSelector {
    func selectTracks(
        mappedTrackInfo: MappedTrackInfo,
        periodId: MediaPeriodId,
        timeline: Timeline
    ) throws -> (renderersConfig: [Bool?], selections: [SETrackSelection?])
}

extension MappingTrackSelector {
    func selectTracks(
        rendererCapabilities: [RendererCapabilities],
        trackGroups: [TrackGroup],
        periodId: MediaPeriodId,
        timeline: Timeline
    ) throws -> TrackSelectionResult {
        let mappedTrackInfo = MappedTrackInfo(rendererCount: .zero, rendererTrackTypes: [], rendererTrackGroups: [], unmappedTrackGroups: [])
        let (renderersConfig, selections) = try selectTracks(
            mappedTrackInfo: mappedTrackInfo,
            periodId: periodId,
            timeline: timeline
        )

        return TrackSelectionResult(renderersConfig: renderersConfig, selections: selections, tracks: .empty)
    }

    private func findRenderer(rendererCapabilities: [RendererCapabilities], group: TrackGroup) -> Int? {
        for format in group.formats {
            for (index, rendererCapability) in rendererCapabilities.enumerated() {
                if rendererCapability.supportsFormat(format) {
                    return index
                }
            }
        }

        return nil
    }
}

struct MappedTrackInfo {
    let rendererCount: Int
    let rendererTrackTypes: [TrackType]
    let rendererTrackGroups: [[TrackGroup]]
    let unmappedTrackGroups: [TrackGroup]

    enum RendererSupport {
        
    }
}
//extension MappingTrackSelector {
//    struct MappedTrackInfo {
//        let rendererCount: Int
//        let rendererTrackTypes: [TrackType]
//        let rendererTrackGroups: [[TrackGroup]]
//        let unmappedTrackGroups: [TrackGroup]
//
//        enum RendererSupport {
//            
//        }
//    }
//}
