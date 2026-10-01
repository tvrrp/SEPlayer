//
//  HlsMediaPlaylist.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.08.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

public struct HlsMediaPlaylist {
    public struct ServerControl {}

    struct Segment: Hashable {
        let url: String
        let byteRange: Range<Int>?
        let initializationSegment: InitializationSegment?
        let relativeStartTime: CMTime
        let duration: CMTime
        let relativeDiscontinuitySequence: Int
        let encryption: SegmentEncryption?
        let hasGapTag: Bool
        let parts: [Part]
    }

    struct Part: Hashable {
        let url: String
        let byteRange: Range<Int>?
        let initializationSegment: InitializationSegment?
        let relativeStartTime: CMTime
        let duration: CMTime
        let relativeDiscontinuitySequence: Int
        let encryption: SegmentEncryption?
        let hasGapTag: Bool
        let isIndependent: Bool
        let isPreload: Bool
    }

    struct InitializationSegment: Hashable {
        let url: String
        let byteRange: Range<Int>?
        let encryption: SegmentEncryption?
    }

    struct SegmentEncryption: Hashable {
        let keyURL: String?
        let iv: String?
    }

    public struct RenditionReport {}
    public struct Interstitial {}
    public struct ClientDefinedAttribute {}

    /// Type of the playlist, as defined by #EXT-X-PLAYLIST-TYPE.
    public enum PlaylistType {
        case unknown
        case vod
        case event
    }
}
