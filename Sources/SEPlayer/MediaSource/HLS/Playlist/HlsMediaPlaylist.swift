//
//  HlsMediaPlaylist.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.08.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.hls.playlist.HlsMediaPlaylist
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Represents an HLS media playlist.
public struct HlsMediaPlaylist: HlsPlaylist {
    /// Type of the playlist, as defined by #EXT-X-PLAYLIST-TYPE.
    public enum PlaylistType: Hashable, Sendable {
        case unknown
        case vod
        case event
    }

    /// Server control attributes, as defined by #EXT-X-SERVER-CONTROL.
    public struct ServerControl: Hashable, Sendable {
        /// The skip boundary for delta updates, or `.invalid` if delta updates are not supported.
        public let skipUntil: CMTime
        /// Whether the playlist can produce delta updates that skip older #EXT-X-DATERANGE tags.
        public let canSkipDateRanges: Bool
        /// The server-recommended live offset, or `.invalid` if none is defined.
        public let holdBack: CMTime
        /// The server-recommended live offset in low-latency mode, or `.invalid` if none is defined.
        public let partHoldBack: CMTime
        /// Whether the server supports blocking playlist reload.
        public let canBlockReload: Bool

        public static let none = ServerControl(
            skipUntil: .invalid,
            canSkipDateRanges: false,
            holdBack: .invalid,
            partHoldBack: .invalid,
            canBlockReload: false
        )
    }

    /// Media segment reference.
    public struct Segment: Hashable, Sendable {
        /// The url of the segment.
        public let url: URL
        /// The media initialization section for this segment, as defined by #EXT-X-MAP. May be `nil` if the media
        /// playlist does not define a media initialization section for this segment. The same instance is used for
        /// all segments that share an #EXT-X-MAP tag.
        public let initializationSegment: InitializationSegment?
        /// The duration of the segment, as defined by #EXTINF.
        public let duration: CMTime
        /// The human readable title of the segment.
        public let title: String
        /// The number of #EXT-X-DISCONTINUITY tags in the playlist before the segment.
        public let relativeDiscontinuitySequence: Int
        /// The start time of the segment relative to the start of the playlist.
        public let relativeStartTime: CMTime
        /// The encryption of the segment, or `nil` if it is not encrypted.
        public let encryption: SegmentEncryption?
        /// The segment's byte range offset, as defined by #EXT-X-BYTERANGE.
        public let byteRangeOffset: Int
        /// The segment's byte range length, as defined by #EXT-X-BYTERANGE, or `nil` if the segment does not have
        /// a byte range.
        public let byteRangeLength: Int?
        /// Whether the segment is marked as a gap.
        public let hasGapTag: Bool
        /// The parts of the segment, as defined by #EXT-X-PART, in a low-latency playlist; empty otherwise. A server
        /// lists them for the most recent segments only.
        public let parts: [Part]

        public var endTime: CMTime { relativeStartTime + duration }

        /// The segment at another place in a playlist, as when a delta update skips it and the previous playlist
        /// lists it: with its start time and discontinuity count in the new playlist.
        func moved(relativeStartTime: CMTime, relativeDiscontinuitySequence: Int) -> Segment {
            let shift = relativeStartTime - self.relativeStartTime
            return Segment(
                url: url,
                initializationSegment: initializationSegment,
                duration: duration,
                title: title,
                relativeDiscontinuitySequence: relativeDiscontinuitySequence,
                relativeStartTime: relativeStartTime,
                encryption: encryption,
                byteRangeOffset: byteRangeOffset,
                byteRangeLength: byteRangeLength,
                hasGapTag: hasGapTag,
                parts: parts.map { part in
                    Part(
                        url: part.url,
                        initializationSegment: part.initializationSegment,
                        duration: part.duration,
                        relativeDiscontinuitySequence: relativeDiscontinuitySequence,
                        relativeStartTime: part.relativeStartTime + shift,
                        encryption: part.encryption,
                        byteRangeOffset: part.byteRangeOffset,
                        byteRangeLength: part.byteRangeLength,
                        hasGapTag: part.hasGapTag,
                        isIndependent: part.isIndependent,
                        isPreload: part.isPreload
                    )
                }
            )
        }
    }

    /// The latest segment and part of another rendition of the stream, as defined by #EXT-X-RENDITION-REPORT.
    public struct RenditionReport: Hashable, Sendable {
        /// The url of the rendition's media playlist.
        public let url: URL
        /// The media sequence number of the rendition's last segment.
        public let lastMediaSequence: Int
        /// The index of the last part of that segment, or `nil` if the playlist isn't low latency.
        public let lastPartIndex: Int?
    }

    /// A part of a segment, as defined by #EXT-X-PART, or the part an #EXT-X-PRELOAD-HINT announces.
    public struct Part: Hashable, Sendable {
        /// The url of the part.
        public let url: URL
        /// The media initialization section of the part, or `nil` if there is none.
        public let initializationSegment: InitializationSegment?
        /// The duration of the part; the part target duration for a preload part, which isn't complete yet.
        public let duration: CMTime
        /// The number of #EXT-X-DISCONTINUITY tags in the playlist before the part.
        public let relativeDiscontinuitySequence: Int
        /// The start time of the part relative to the start of the playlist.
        public let relativeStartTime: CMTime
        /// The encryption of the part, or `nil` if it is not encrypted.
        public let encryption: SegmentEncryption?
        /// The part's byte range offset.
        public let byteRangeOffset: Int
        /// The part's byte range length, or `nil` if the part does not have a byte range.
        public let byteRangeLength: Int?
        /// Whether the part is marked as a gap.
        public let hasGapTag: Bool
        /// Whether the part starts with a keyframe: playback can start at it.
        public let isIndependent: Bool
        /// Whether an #EXT-X-PRELOAD-HINT announces the part: the server delivers it once it's ready.
        public let isPreload: Bool

        public var endTime: CMTime { relativeStartTime + duration }
    }

    /// The media initialization section, as defined by #EXT-X-MAP.
    public struct InitializationSegment: Hashable, Sendable {
        /// The url of the initialization section.
        public let url: URL
        /// The byte range offset of the initialization section.
        public let byteRangeOffset: Int
        /// The byte range length of the initialization section, or `nil` if it does not have a byte range.
        public let byteRangeLength: Int?
        /// The encryption of the initialization section, or `nil` if it is not encrypted.
        public let encryption: SegmentEncryption?
    }

    /// Full segment encryption with AES-128, as defined by #EXT-X-KEY with `METHOD=AES-128`.
    public struct SegmentEncryption: Hashable, Sendable {
        /// The url of the key.
        public let keyUrl: URL
        /// The initialization vector, or `nil` if the media sequence number of the segment is used instead.
        public let iv: Data?

        /// The initialization vector for the segment with `mediaSequence`: the IV attribute, or the sequence number
        /// as a big-endian 128-bit integer.
        public func iv(forMediaSequence mediaSequence: Int) -> Data {
            if let iv { return iv }
            var bytes = [UInt8](repeating: 0, count: 16)
            var value = UInt64(clamping: mediaSequence)
            for index in stride(from: 15, through: 8, by: -1) {
                bytes[index] = UInt8(value & 0xFF)
                value >>= 8
            }
            return Data(bytes)
        }
    }

    public let baseUrl: String
    public let tags: [String]
    public let hasIndependentSegments: Bool

    /// The type of the playlist.
    public let playlistType: PlaylistType
    /// The start offset as defined by #EXT-X-START, or `.invalid` if not defined. Negative values are relative to
    /// the end of the playlist.
    public let startOffset: CMTime
    /// Whether the start position should be precise, as defined by #EXT-X-START.
    public let preciseStart: Bool
    /// If #EXT-X-PROGRAM-DATE-TIME is present, the wall clock time of the first segment, otherwise zero.
    public let startTime: CMTime
    /// Whether the playlist declares a discontinuity sequence number.
    public let hasDiscontinuitySequence: Bool
    /// The discontinuity sequence number of the first media segment in the playlist, as defined by
    /// #EXT-X-DISCONTINUITY-SEQUENCE.
    public let discontinuitySequence: Int
    /// The media sequence number of the first media segment in the playlist, as defined by #EXT-X-MEDIA-SEQUENCE.
    public let mediaSequence: Int
    /// The compatibility version, as defined by #EXT-X-VERSION.
    public let version: Int
    /// The target duration, as defined by #EXT-X-TARGETDURATION.
    public let targetDuration: CMTime
    /// Whether the playlist contains the #EXT-X-ENDLIST tag.
    public let hasEndTag: Bool
    /// Whether the playlist contains a #EXT-X-PROGRAM-DATE-TIME tag.
    public let hasProgramDateTime: Bool
    /// The list of segments in the playlist.
    public let segments: [Segment]
    /// The part target duration, as defined by #EXT-X-PART-INF, or `.invalid` if the playlist isn't low latency.
    public let partTargetDuration: CMTime
    /// The parts after the last segment: those of the segment that isn't complete yet, the preload part last.
    public let trailingParts: [Part]
    /// The server control attributes.
    public let serverControl: ServerControl
    /// The latest segment and part of the other renditions, by the url of their media playlist.
    public let renditionReports: [URL: RenditionReport]
    /// The total duration of the playlist, to the end of the last part that is available.
    public let duration: CMTime
    /// Whether each segment is a single keyframe, as in the playlist of an #EXT-X-I-FRAME-STREAM-INF tag: its
    /// duration lasts until the next keyframe.
    public let isIFramesOnly: Bool

    /// The media sequence number of the segment after the last one.
    public var endMediaSequence: Int { mediaSequence + segments.count }

    /// The end time of the playlist, on the time of ``startTime``.
    public var endTime: CMTime { startTime + duration }

    /// Whether #EXT-X-START gives a start inside the playlist, rather than at its end.
    public var hasPositiveStartOffset: Bool { startOffset.isValid && startOffset < duration }

    /// Whether the playlist is low latency: it lists parts, and the player can follow them.
    public var isLowLatency: Bool { partTargetDuration.isValid }

    public init(
        baseUrl: String,
        tags: [String],
        hasIndependentSegments: Bool,
        playlistType: PlaylistType,
        startOffset: CMTime,
        preciseStart: Bool,
        startTime: CMTime,
        hasDiscontinuitySequence: Bool,
        discontinuitySequence: Int,
        mediaSequence: Int,
        version: Int,
        targetDuration: CMTime,
        hasEndTag: Bool,
        hasProgramDateTime: Bool,
        segments: [Segment],
        partTargetDuration: CMTime = .invalid,
        trailingParts: [Part] = [],
        serverControl: ServerControl,
        renditionReports: [URL: RenditionReport] = [:],
        isIFramesOnly: Bool = false
    ) {
        self.isIFramesOnly = isIFramesOnly
        self.baseUrl = baseUrl
        self.tags = tags
        self.hasIndependentSegments = hasIndependentSegments
        self.playlistType = playlistType
        self.preciseStart = preciseStart
        self.startTime = startTime
        self.hasDiscontinuitySequence = hasDiscontinuitySequence
        self.discontinuitySequence = discontinuitySequence
        self.mediaSequence = mediaSequence
        self.version = version
        self.targetDuration = targetDuration
        self.hasEndTag = hasEndTag
        self.hasProgramDateTime = hasProgramDateTime
        self.segments = segments
        self.partTargetDuration = partTargetDuration
        self.trailingParts = trailingParts
        self.serverControl = serverControl
        self.renditionReports = renditionReports

        // The preload part isn't there yet.
        let duration = trailingParts.last(where: { !$0.isPreload })?.endTime ?? segments.last?.endTime ?? .zero
        self.duration = duration
        if startOffset.isValid {
            // A negative offset is relative to the end; either way it stays within the playlist.
            let resolved = startOffset < .zero ? max(.zero, duration + startOffset) : startOffset
            self.startOffset = min(resolved, duration)
        } else {
            self.startOffset = .invalid
        }
    }

    /// The playlist with another start time and discontinuity sequence: those of a playlist that doesn't declare
    /// them, carried over from the snapshot it updates.
    public func copyWith(startTime: CMTime, discontinuitySequence: Int) -> HlsMediaPlaylist {
        copy(
            startTime: startTime,
            discontinuitySequence: discontinuitySequence,
            hasDiscontinuitySequence: true,
            hasEndTag: hasEndTag
        )
    }

    /// The playlist with #EXT-X-ENDLIST: a reload of the same segments that ended the stream.
    public func copyWithEndTag() -> HlsMediaPlaylist {
        guard !hasEndTag else { return self }
        return copy(
            startTime: startTime,
            discontinuitySequence: discontinuitySequence,
            hasDiscontinuitySequence: hasDiscontinuitySequence,
            hasEndTag: true
        )
    }

    /// The report of the rendition with `url`: by its url, or by its path when the report leaves out some of the
    /// query, as a session id.
    public func renditionReport(for url: URL) -> RenditionReport? {
        if let report = renditionReports[url] { return report }
        return renditionReports.values.first { $0.url.host == url.host && $0.url.path == url.path }
    }

    /// Whether this playlist is newer than `other`, for playlists of the same rendition.
    public func isNewer(than other: HlsMediaPlaylist?) -> Bool {
        guard let other else { return true }
        if mediaSequence != other.mediaSequence { return mediaSequence > other.mediaSequence }
        if segments.count != other.segments.count { return segments.count > other.segments.count }
        let parts = trailingParts.filter { !$0.isPreload }.count
        let otherParts = other.trailingParts.filter { !$0.isPreload }.count
        if parts != otherParts { return parts > otherParts }
        return hasEndTag && !other.hasEndTag
    }

    /// The parts of the segment with `mediaSequence`: its own once it is complete, the trailing parts while it is the
    /// segment being made, or none for a segment the playlist doesn't list parts for.
    public func parts(ofMediaSequence mediaSequence: Int) -> [Part] {
        let index = mediaSequence - self.mediaSequence
        if index == segments.count { return trailingParts }
        return segments.indices.contains(index) ? segments[index].parts : []
    }

    private func copy(
        startTime: CMTime,
        discontinuitySequence: Int,
        hasDiscontinuitySequence: Bool,
        hasEndTag: Bool
    ) -> HlsMediaPlaylist {
        HlsMediaPlaylist(
            baseUrl: baseUrl,
            tags: tags,
            hasIndependentSegments: hasIndependentSegments,
            playlistType: playlistType,
            startOffset: startOffset,
            preciseStart: preciseStart,
            startTime: startTime,
            hasDiscontinuitySequence: hasDiscontinuitySequence,
            discontinuitySequence: discontinuitySequence,
            mediaSequence: mediaSequence,
            version: version,
            targetDuration: targetDuration,
            hasEndTag: hasEndTag,
            hasProgramDateTime: hasProgramDateTime,
            segments: segments,
            partTargetDuration: partTargetDuration,
            trailingParts: trailingParts,
            serverControl: serverControl,
            renditionReports: renditionReports,
            isIFramesOnly: isIFramesOnly
        )
    }
}
