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
    func selectTracks(trackGroups: [TrackGroup], periodId: MediaPeriodId, timeline: Timeline) -> TrackSelectionResult
}

struct DefaultTrackSelector: TrackSelector {
    func selectTracks(trackGroups: [TrackGroup], periodId: MediaPeriodId, timeline: Timeline) -> TrackSelectionResult {
        let updatedGroups: [TrackGroup] = trackGroups.compactMap { group in
            let format = group.formats[0]
            switch format.mediaType {
            case .video:
                return supportsVideoFormat(format) ? group : nil
            case .audio:
                return supportsAudioFormat(format) ? group : nil
            default:
                return nil
            }
        }
        return TrackSelectionResult(
            selections: updatedGroups.map { FixedTrackSelection(trackGroup: $0) },
            tracks: Tracks.empty
        )
    }

    private func supportsVideoFormat(_ format: CMFormatDescription) -> Bool {
        switch format.mediaSubType.rawValue {
        case kCMVideoCodecType_H264:
            return true
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_VP9, kCMVideoCodecType_AV1:
            return false
        default:
            return false
        }
    }

    private func supportsAudioFormat(_ format: CMFormatDescription) -> Bool {
        switch format.mediaSubType {
        case .mpeg4AAC:
            return true
        default:
            return false
        }
    }
}
