//
//  Tracks.swift
//  SEPlayerCommon
//
//  Created by tvrrp on 13.02.2026.
//


/// Information about groups of tracks.
public struct Tracks: Hashable, Sendable {
    /// The groups of tracks.
    public let groups: [Group]

    public init(groups: [Group]) {
        self.groups = groups
    }
    /// Whether there are no groups of tracks.
    public var isEmpty: Bool { groups.isEmpty }

    public func containsType(_ type: TrackType) -> Bool {
        for group in groups {
            if group.mediaTrackGroup.type == type {
                return true
            }
        }
        return false
    }

    public func typeSupported(_ trackType: TrackType, allowExceedsCapabilities: Bool = false) -> Bool {
        for group in groups {
            if group.mediaTrackGroup.type == trackType, group.isSupported(allowExceedsCapabilities: allowExceedsCapabilities) {
                return true
            }
        }

        return false
    }

    public func isSupportedOrEmpty(trackType: TrackType, allowExceedsCapabilities: Bool = false) -> Bool {
        return !containsType(trackType) || typeSupported(trackType, allowExceedsCapabilities: allowExceedsCapabilities)
    }

    public func typeSelected(for trackType: TrackType) -> Bool {
        for group in groups {
            if group.isSelected && group.mediaTrackGroup.type == trackType {
                return true
            }
        }

        return false
    }
}

public extension Tracks {
    /// An empty instance.
    static let empty = Tracks(groups: [])

    /// A group of tracks: a `TrackGroup` with whether each track is supported and selected.
    struct Group: Hashable, Sendable {
        public var length: Int { mediaTrackGroup.length }
        /// The underlying `TrackGroup` defined by the media.
        public let mediaTrackGroup: TrackGroup
        /// Whether adaptive selections containing more than one track are supported.
        public let adaptiveSupported: Bool
        let trackSupport: [FormatSupport]
        let trackSelected: [Bool]

        /// - Parameters:
        ///   - trackSupport: How well each track is supported.
        ///   - trackSelected: Whether each track is selected.
        public init(mediaTrackGroup: TrackGroup, adaptiveSupported: Bool, trackSupport: [FormatSupport], trackSelected: [Bool]) {
            precondition(trackSupport.count == mediaTrackGroup.length && trackSelected.count == mediaTrackGroup.length)
            self.mediaTrackGroup = mediaTrackGroup
            self.adaptiveSupported = adaptiveSupported && mediaTrackGroup.length > 1
            self.trackSupport = trackSupport
            self.trackSelected = trackSelected
        }

        /// Whether at least one track in the group is selected.
        public var isSelected: Bool { trackSelected.contains(true) }
        /// The type of the tracks in the group.
        public var type: TrackType { mediaTrackGroup.type }

        public func format(trackIndex: Int) -> Format {
            mediaTrackGroup[trackIndex]
        }

        public func trackSupport(for index: Int) -> FormatSupport {
            trackSupport[index]
        }

        public func isTrackSupported(for trackIndex: Int, allowExceedsCapabilities: Bool = false) -> Bool {
            trackSupport[trackIndex] == .handled || (allowExceedsCapabilities && trackSupport[trackIndex] == .exceedCapabilities)
        }

        public func isSupported(allowExceedsCapabilities: Bool = false) -> Bool {
            for index in 0..<trackSupport.count {
                if isTrackSupported(for: index, allowExceedsCapabilities: allowExceedsCapabilities) {
                    return true
                }
            }

            return false
        }

        public func isTrackSelected(for trackIndex: Int) -> Bool {
            return trackSelected[trackIndex]
        }
    }
}

/// How well a format is supported, from not at all to fully.
public enum FormatSupport: Comparable, Sendable {
    /// The type of the format isn't supported.
    case unsupportedType
    /// The type is supported, but not the subtype, such as the codec.
    case unsupportedSubtype
    /// The format is supported, but not its content protection.
    case unsupportedDrm
    /// The format is supported, but exceeds what the device can do, such as its maximum resolution: playback may
    /// fail.
    case exceedCapabilities
    /// The format is supported.
    case handled
}
