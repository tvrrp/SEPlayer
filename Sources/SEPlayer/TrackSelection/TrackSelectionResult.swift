//
//  TrackSelectionResult.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

public struct TrackSelectionResult: Equatable {
    let renderersConfig: [Bool?]
    let selections: [SETrackSelection?]
    let tracks: Tracks

    public static func == (lhs: TrackSelectionResult, rhs: TrackSelectionResult) -> Bool {
        guard lhs.selections.count == rhs.selections.count else { return false }

        for (firstSelection, secondSelection) in zip(lhs.selections, rhs.selections) {
            guard let firstSelection, let secondSelection else {
                return false
            }

            return true // TODO: compare properly
        }

        return true
    }

    func isRendererEnabled(for index: Int) -> Bool {
        renderersConfig[index] != nil
    }
}

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
        let trackSupport: [FormatSupported]
        let trackSelected: [Bool]

        var isSelected: Bool { trackSelected.contains(true) }

        func format(for trackIndex: Int) -> Format {
            mediaTrackGroup.formats[trackIndex]
        }

        func trackSupport(for index: Int) -> FormatSupported {
            trackSupport[index]
        }

        func isTrackSupported(for trackIndex: Int, allowExceedsCapabilities: Bool = false) -> Bool {
            trackSupport[trackIndex] == .handled || (allowExceedsCapabilities && trackSupport[trackIndex] == .exceedsCapabilities)
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

enum FormatSupported {
    case handled
    case exceedsCapabilities
    case unsuportedDrm
    case unsuportedSubtype
    case unsuportedType
}
