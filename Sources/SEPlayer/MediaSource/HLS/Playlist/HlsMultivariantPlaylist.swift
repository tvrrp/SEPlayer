//
//  HlsMultivariantPlaylist.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.08.2026.
//

import Foundation
import SEPlayerCommon

/// Represents an HLS multivariant playlist.
public struct HlsMultivariantPlaylist: HlsPlaylist, Hashable {
    public enum GroupIndex: Hashable {
        case variant
        case audio
        case subtitle
    }

    /// A variant (i.e. an #EXT-X-STREAM-INF tag) in a multivariant playlist.
    public struct Variant: Hashable {
        /// The variant's url.
        public let url: URL
        /// Format information associated with this variant.
        public let format: Format
        /// The video rendition group referenced by this variant.
        public let videoGroupId: String?
        /// The audio rendition group referenced by this variant.
        public let audioGroupId: String?
        /// The subtitle rendition group referenced by this variant.
        public let subtitleGroupId: String?
        /// The caption rendition group referenced by this variant.
        public let captionGroupId: String?
        /// The identifier of the pathway that this variant belongs.
        public let pathwayId: String?
        /// The stable identifier for this variant.
        public let stableVariantId: String?

        public init(
            url: URL,
            format: Format,
            videoGroupId: String? = nil,
            audioGroupId: String? = nil,
            subtitleGroupId: String? = nil,
            captionGroupId: String? = nil,
            pathwayId: String? = nil,
            stableVariantId: String? = nil
        ) {
            self.url = url
            self.format = format
            self.videoGroupId = videoGroupId
            self.audioGroupId = audioGroupId
            self.subtitleGroupId = subtitleGroupId
            self.captionGroupId = captionGroupId
            self.pathwayId = pathwayId
            self.stableVariantId = stableVariantId
        }

        public static func createMediaPlaylistVariantUrl(_ url: URL) -> Variant {
            let format = Format.Builder()
                .setId(0)
                .setContainerMimeType(.applicationM3U8)
                .build()

            return Variant(url: url, format: format)
        }

        public func copyWithFormat(_ format: Format) -> Variant {
            return Variant(
                url: self.url,
                format: format,
                videoGroupId: self.videoGroupId,
                audioGroupId: self.audioGroupId,
                subtitleGroupId: self.subtitleGroupId,
                captionGroupId: self.captionGroupId,
                pathwayId: self.pathwayId,
                stableVariantId: self.stableVariantId
            )
        }
    }

    /// A rendition (i.e. an #EXT-X-MEDIA tag) in a multivariant playlist.
    public struct Rendition: Hashable {
        /// The rendition's url, or nil if the tag does not have a URI attribute.
        public let url: URL?
        /// Format information associated with this rendition.
        public let format: Format
        /// The group to which this rendition belongs.
        public let groupId: String
        /// The name of the rendition.
        public let name: String
        /// The stable identifier for this rendition.
        public let stableRenditionId: String?

        public init(
            url: URL?,
            format: Format,
            groupId: String,
            name: String,
            stableRenditionId: String?
        ) {
            self.url = url
            self.format = format
            self.groupId = groupId
            self.name = name
            self.stableRenditionId = stableRenditionId
        }
    }

    /// Content Steering information derived from an #EXT-X-CONTENT-STEERING tag.
    public struct ContentSteeringInfo: Hashable {
        /// A URL to a Steering Manifest.
        public let serverUrl: URL
        /// The ID of a pathway that must be used until the initial Steering Manifest has been obtained,
        /// or nil which suggests that any available pathway can be used until the initial
        /// Steering Manifest has been obtained.
        public let pathwayId: String

        public init(serverUrl: URL, pathwayId: String) {
            self.serverUrl = serverUrl
            self.pathwayId = pathwayId
        }
    }

    public let baseUrl: String
    public let tags: [String]
    public let hasIndependentSegments: Bool

    /// All of the media playlist URLs referenced by the playlist.
    public let mediaPlaylistUrls: [URL]
    /// The variants declared by the playlist.
    public let variants: [Variant]
    /// The video renditions declared by the playlist.
    public let videos: [Rendition]
    /// The audio renditions declared by the playlist.
    public let audios: [Rendition]
    /// The subtitle renditions declared by the playlist.
    public let subtitles: [Rendition]
    /// The closed caption declared by the playlist.
    public let closedCaptions: [Rendition]
    /// The format of the audio muxed in the variants. May be null if the playlist does not declare any
    /// muxed audio.
    public let muxedAudioFormat: Format?
    /// The format of the closed captions declared by the playlist. May be empty if the playlist
    /// explicitly declares no captions are available, or null if the playlist does not declare any
    /// captions information.
    public let muxedCaptionFormats: Format?
    /// Contains variable definitions, as defined by the #EXT-X-DEFINE tag.
    public let variableDefinitions: [String: String]
    /// DRM initialization data derived from #EXT-X-SESSION-KEY tags.
    public let sessionKeyDrmInitData: [Int]
    // TODO: public let sessionKeyDrmInitData: [DRMInitData]
    /// Content Steering information derived from #EXT-X-CONTENT-STEERING tag.
    public let contentSteeringInfo: ContentSteeringInfo?

    public init(
        baseUrl: String,
        tags: [String],
        variants: [Variant],
        videos: [Rendition],
        audios: [Rendition],
        subtitles: [Rendition],
        closedCaptions: [Rendition],
        muxedAudioFormat: Format?,
        muxedCaptionFormats: Format?,
        hasIndependentSegments: Bool,
        variableDefinitions: [String : String],
        sessionKeyDrmInitData: [Int],
        contentSteeringInfo: ContentSteeringInfo?
    ) {
        self.baseUrl = baseUrl
        self.tags = tags
        self.hasIndependentSegments = hasIndependentSegments

        self.mediaPlaylistUrls = Self.getMediaPlaylistUrls(
            variants: variants,
            videos: videos,
            audios: audios,
            subtitles: subtitles,
            closedCaptions: closedCaptions
        )

        self.variants = variants
        self.videos = videos
        self.audios = audios
        self.subtitles = subtitles
        self.closedCaptions = closedCaptions
        self.muxedAudioFormat = muxedAudioFormat
        self.muxedCaptionFormats = muxedCaptionFormats
        self.variableDefinitions = variableDefinitions
        self.sessionKeyDrmInitData = sessionKeyDrmInitData
        self.contentSteeringInfo = contentSteeringInfo
    }

    /// Creates a playlist with a single variant.
    /// - Parameter variantUrl: The url of the single variant.
    /// - Returns: A multivariant playlist with a single variant for the provided url.
    public func createSingleVariantMultivariantPlaylist(from variantUrl: String) throws -> Self? {
        guard let url = URL(string: variantUrl) else {
            return nil
        }

        return HlsMultivariantPlaylist(
            baseUrl: "",
            tags: [],
            variants: [Variant.createMediaPlaylistVariantUrl(url)],
            videos: [],
            audios: [],
            subtitles: [],
            closedCaptions: [],
            muxedAudioFormat: nil,
            muxedCaptionFormats: nil,
            hasIndependentSegments: false,
            variableDefinitions: [:],
            sessionKeyDrmInitData: [],
            contentSteeringInfo: nil
        )
    }

    private static func getMediaPlaylistUrls(
        variants: [Variant],
        videos: [Rendition],
        audios: [Rendition],
        subtitles: [Rendition],
        closedCaptions: [Rendition]
    ) -> [URL] {
        let renditionUrls = [videos, audios, subtitles, closedCaptions]
            .joined()
            .compactMap(\.url)

        return Array(Set(variants.map(\.url) + renditionUrls))
    }
}
