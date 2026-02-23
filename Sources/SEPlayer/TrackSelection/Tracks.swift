//
//  Tracks.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//

struct Tracks: Hashable {
    let groups: [Group]
    var isEmpty: Bool { groups.isEmpty }

    func containsType(_ type: TrackType) -> Bool {
        for group in groups {
            if group.mediaTrackGroup.type == type {
                return true
            }
        }
        return false
    }

    func typeSupported(_ trackType: TrackType, allowExceedsCapabilities: Bool = false) -> Bool {
        for group in groups {
            if group.mediaTrackGroup.type == trackType, group.isSupported(allowExceedsCapabilities: allowExceedsCapabilities) {
                return true
            }
        }

        return false
    }

    func isSupportedOrEmpty(trackType: TrackType, allowExceedsCapabilities: Bool = false) -> Bool {
        return !containsType(trackType) || typeSupported(trackType, allowExceedsCapabilities: allowExceedsCapabilities)
    }

    func typeSelected(for trackType: TrackType) -> Bool {
        for group in groups {
            if group.isSelected && group.mediaTrackGroup.type == trackType {
                return true
            }
        }

        return false
    }
}

extension Tracks {
    static var empty: Tracks = Tracks(groups: [])

    struct Group: Hashable {
        var length: Int { mediaTrackGroup.length }
        let mediaTrackGroup: TrackGroup
        let adaptiveSupported: Bool
        let trackSupport: [RendererCapabilities.Support.FormatSupport]
        let trackSelected: [Bool]

        var isSelected: Bool { trackSelected.contains(true) }
        var type: TrackType { mediaTrackGroup.type }

        func format(trackIndex: Int) -> Format {
            mediaTrackGroup[trackIndex]
        }

        func trackSupport(for index: Int) -> RendererCapabilities.Support.FormatSupport {
            trackSupport[index]
        }

        func isTrackSupported(for trackIndex: Int, allowExceedsCapabilities: Bool = false) -> Bool {
            trackSupport[trackIndex] == .handled || (allowExceedsCapabilities && trackSupport[trackIndex] == .exceedCapabilities)
        }

        func isSupported(allowExceedsCapabilities: Bool = false) -> Bool {
            for index in 0..<trackSupport.count {
                if isTrackSupported(for: index, allowExceedsCapabilities: allowExceedsCapabilities) {
                    return true
                }
            }

            return false
        }

        func isTrackSelected(for trackIndex: Int) -> Bool {
            return trackSelected[trackIndex]
        }
    }
}
