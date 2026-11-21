//
//  MediaItem.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

/// Representation of a media item.
public struct MediaItem: Hashable, Sendable {
    /// The default media ID that is used if the media ID is not explicitly set by ``Builder/setMediaId(_:)``.
    public static let defaultMediaId = ""

    /// Empty ``MediaItem``.
    public static let empty = MediaItem.Builder().build()

    /// Identifies the media item.
    public let mediaId: String

    /// Optional configuration for local playback. May be `nil` if shared over process boundaries.
    public let localConfiguration: LocalConfiguration?

    /// The live playback configuration.
    public let liveConfiguration: LiveConfiguration

    /// The media metadata.
    public let mediaMetadata: MediaMetadata

    /// The clipping properties.
    public let clippingConfiguration: ClippingConfiguration

    /// The media ``RequestMetadata``.
    public let requestMetadata: RequestMetadata

    fileprivate init(
        mediaId: String,
        clippingConfiguration: ClippingConfiguration,
        localConfiguration: LocalConfiguration?,
        liveConfiguration: LiveConfiguration,
        mediaMetadata: MediaMetadata,
        requestMetadata: RequestMetadata
    ) {
        self.mediaId = mediaId
        self.localConfiguration = localConfiguration
        self.liveConfiguration = liveConfiguration
        self.mediaMetadata = mediaMetadata
        self.clippingConfiguration = clippingConfiguration
        self.requestMetadata = requestMetadata
    }

    /// Creates a ``MediaItem`` for the given URL.
    ///
    /// - Parameter url: The URL.
    /// - Returns: An ``MediaItem`` for the given URL.
    public static func from(url: URL) -> MediaItem {
        Builder().setUrl(url).build()
    }

    /// Returns a ``Builder`` initialized with the values of this instance.
    public func buildUpon() -> Builder { Builder(mediaItem: self) }
}

// MARK: - Builder

public extension MediaItem {
    /// A builder for ``MediaItem`` instances.
    final class Builder {
        private var mediaId: String?
        private var url: URL?
        private var mimeType: String?
        private var clippingConfiguration: ClippingConfiguration
        private var drmConfiguration: DrmConfiguration?
        private var streamKeys: [StreamKey]
        private var customCacheKey: String?
        private var subtitleConfigurations: [SubtitleConfiguration]
        private var adsConfiguration: AdsConfiguration?
        private var tag: AnyHashable?
        private var imageDuration: CMTime
        private var mediaMetadata: MediaMetadata?
        private var liveConfiguration: LiveConfiguration
        private var requestMetadata: RequestMetadata

        /// Creates a builder.
        public init() {
            clippingConfiguration = .unset
            streamKeys = []
            subtitleConfigurations = []
            liveConfiguration = .unset
            requestMetadata = .empty
            imageDuration = .invalid
        }

        fileprivate convenience init(mediaItem: MediaItem) {
            self.init()
            clippingConfiguration = mediaItem.clippingConfiguration
            mediaId = mediaItem.mediaId
            mediaMetadata = mediaItem.mediaMetadata
            liveConfiguration = mediaItem.liveConfiguration
            requestMetadata = mediaItem.requestMetadata
            if let localConfiguration = mediaItem.localConfiguration {
                customCacheKey = localConfiguration.customCacheKey
                mimeType = localConfiguration.mimeType
                url = localConfiguration.url
                streamKeys = localConfiguration.streamKeys
                subtitleConfigurations = localConfiguration.subtitleConfigurations
                tag = localConfiguration.tag
                drmConfiguration = localConfiguration.drmConfiguration
                adsConfiguration = localConfiguration.adsConfiguration
                imageDuration = localConfiguration.imageDuration
            }
        }

        /// Sets the optional media ID which identifies the media item.
        ///
        /// By default ``MediaItem/defaultMediaId`` is used.
        @discardableResult
        public func setMediaId(_ mediaId: String) -> Builder {
            self.mediaId = mediaId
            return self
        }

        /// Sets the optional URL.
        ///
        /// If `url` is `nil` or unset then no ``LocalConfiguration`` object is created during ``build()`` and no other
        /// `Builder` methods that would populate ``MediaItem/localConfiguration`` should be called.
        @discardableResult
        public func setUrl(_ url: URL?) -> Builder {
            self.url = url
            return self
        }

        /// Sets the optional MIME type.
        ///
        /// The MIME type may be used as a hint for inferring the type of the media item.
        ///
        /// This method should only be called if ``setUrl(_:)`` is passed a non-`nil` value.
        @discardableResult
        public func setMimeType(_ mimeType: String?) -> Builder {
            self.mimeType = mimeType
            return self
        }

        /// Sets the ``ClippingConfiguration``, defaults to ``ClippingConfiguration/unset``.
        @discardableResult
        public func setClippingConfiguration(_ clippingConfiguration: ClippingConfiguration) -> Builder {
            self.clippingConfiguration = clippingConfiguration
            return self
        }

        /// Sets the optional DRM configuration.
        ///
        /// This method should only be called if ``setUrl(_:)`` is passed a non-`nil` value.
        @discardableResult
        public func setDrmConfiguration(_ drmConfiguration: DrmConfiguration?) -> Builder {
            self.drmConfiguration = drmConfiguration
            return self
        }

        /// Sets the optional stream keys by which the manifest is filtered (only used for adaptive streams).
        ///
        /// `nil` or an empty list can be used for a reset.
        ///
        /// This method should only be called if ``setUrl(_:)`` is passed a non-`nil` value.
        @discardableResult
        public func setStreamKeys(_ streamKeys: [StreamKey]?) -> Builder {
            self.streamKeys = streamKeys ?? []
            return self
        }

        /// Sets the optional custom cache key (only used for progressive streams).
        ///
        /// This method should only be called if ``setUrl(_:)`` is passed a non-`nil` value.
        @discardableResult
        public func setCustomCacheKey(_ customCacheKey: String?) -> Builder {
            self.customCacheKey = customCacheKey
            return self
        }

        /// Sets the optional subtitles.
        ///
        /// This method should only be called if ``setUrl(_:)`` is passed a non-`nil` value.
        @discardableResult
        public func setSubtitleConfigurations(_ subtitleConfigurations: [SubtitleConfiguration]) -> Builder {
            self.subtitleConfigurations = subtitleConfigurations
            return self
        }

        /// Sets the optional ``AdsConfiguration``.
        ///
        /// This method should only be called if ``setUrl(_:)`` is passed a non-`nil` value.
        @discardableResult
        public func setAdsConfiguration(_ adsConfiguration: AdsConfiguration?) -> Builder {
            self.adsConfiguration = adsConfiguration
            return self
        }

        /// Sets the ``LiveConfiguration``. Defaults to ``LiveConfiguration/unset``.
        @discardableResult
        public func setLiveConfiguration(_ liveConfiguration: LiveConfiguration) -> Builder {
            self.liveConfiguration = liveConfiguration
            return self
        }

        /// Sets the optional tag for custom attributes. The tag for the media source which will be published in the
        /// `Timeline` of the source as `Window.mediaItem`.
        ///
        /// This method should only be called if ``setUrl(_:)`` is passed a non-`nil` value.
        @discardableResult
        public func setTag(_ tag: AnyHashable?) -> Builder {
            self.tag = tag
            return self
        }

        /// Sets the image duration in video output.
        ///
        /// Must be set if ``setUrl(_:)`` is set to an image MIME type. Must be greater than zero, or `.invalid`.
        @discardableResult
        public func setImageDuration(_ imageDuration: CMTime) -> Builder {
            precondition(imageDuration > .zero || !imageDuration.isValid)
            self.imageDuration = imageDuration
            return self
        }

        /// Sets the media metadata.
        @discardableResult
        public func setMediaMetadata(_ mediaMetadata: MediaMetadata) -> Builder {
            self.mediaMetadata = mediaMetadata
            return self
        }

        /// Sets the request metadata.
        @discardableResult
        public func setRequestMetadata(_ requestMetadata: RequestMetadata) -> Builder {
            self.requestMetadata = requestMetadata
            return self
        }

        /// Returns a new ``MediaItem`` instance with the current builder values.
        public func build() -> MediaItem {
            let localConfiguration = url.map { url in
                LocalConfiguration(
                    url: url,
                    mimeType: mimeType,
                    drmConfiguration: drmConfiguration,
                    adsConfiguration: adsConfiguration,
                    streamKeys: streamKeys,
                    customCacheKey: customCacheKey,
                    subtitleConfigurations: subtitleConfigurations,
                    tag: tag,
                    imageDuration: imageDuration
                )
            }

            return MediaItem(
                mediaId: mediaId ?? MediaItem.defaultMediaId,
                clippingConfiguration: clippingConfiguration,
                localConfiguration: localConfiguration,
                liveConfiguration: liveConfiguration,
                mediaMetadata: mediaMetadata ?? MediaMetadata.Builder().build(),
                requestMetadata: requestMetadata
            )
        }
    }
}

// MARK: - DrmConfiguration

public extension MediaItem {
    /// DRM configuration for a media item.
    struct DrmConfiguration: Hashable, Sendable {
        /// The `UUID` of the protection scheme.
        public let scheme: UUID

        /// Optional default DRM license server URL. If `nil` then the DRM license server must be specified by the media.
        public let licenseUrl: URL?

        /// The headers to attach to requests sent to the DRM license server.
        public let licenseRequestHeaders: [String: String]

        /// Whether the DRM configuration is multi session enabled.
        public let multiSession: Bool

        /// Whether clear samples within protected content should be played when keys for the encrypted part of the
        /// content have yet to be loaded.
        public let playClearContentWithoutKey: Bool

        /// Whether to force use of ``licenseUrl`` even if the media specifies its own DRM license server URL.
        public let forceDefaultLicenseUrl: Bool

        /// The types of tracks for which to always use a DRM session even if the content is unencrypted.
        public let forcedSessionTrackTypes: [TrackType]

        /// The key set ID of the offline license.
        public let keySetId: Data?

        fileprivate init(builder: Builder) {
            precondition(!(builder.forceDefaultLicenseUrl && builder.licenseUrl == nil))
            scheme = builder.scheme
            licenseUrl = builder.licenseUrl
            licenseRequestHeaders = builder.licenseRequestHeaders
            multiSession = builder.multiSession
            playClearContentWithoutKey = builder.playClearContentWithoutKey
            forceDefaultLicenseUrl = builder.forceDefaultLicenseUrl
            forcedSessionTrackTypes = builder.forcedSessionTrackTypes
            keySetId = builder.keySetId
        }

        /// Returns a ``Builder`` initialized with the values of this instance.
        public func buildUpon() -> Builder { Builder(drmConfiguration: self) }

        /// Builder for ``DrmConfiguration``.
        public final class Builder {
            fileprivate var scheme: UUID
            fileprivate var licenseUrl: URL?
            fileprivate var licenseRequestHeaders: [String: String] = [:]
            fileprivate var multiSession = false
            fileprivate var playClearContentWithoutKey = true
            fileprivate var forceDefaultLicenseUrl = false
            fileprivate var forcedSessionTrackTypes: [TrackType] = []
            fileprivate var keySetId: Data?

            /// Constructs an instance.
            ///
            /// - Parameter scheme: The `UUID` of the protection scheme.
            public init(scheme: UUID) {
                self.scheme = scheme
            }

            fileprivate init(drmConfiguration: DrmConfiguration) {
                scheme = drmConfiguration.scheme
                licenseUrl = drmConfiguration.licenseUrl
                licenseRequestHeaders = drmConfiguration.licenseRequestHeaders
                multiSession = drmConfiguration.multiSession
                playClearContentWithoutKey = drmConfiguration.playClearContentWithoutKey
                forceDefaultLicenseUrl = drmConfiguration.forceDefaultLicenseUrl
                forcedSessionTrackTypes = drmConfiguration.forcedSessionTrackTypes
                keySetId = drmConfiguration.keySetId
            }

            /// Sets the `UUID` of the protection scheme.
            @discardableResult
            public func setScheme(_ scheme: UUID) -> Builder {
                self.scheme = scheme
                return self
            }

            /// Sets the optional default DRM license server URL.
            @discardableResult
            public func setLicenseUrl(_ licenseUrl: URL?) -> Builder {
                self.licenseUrl = licenseUrl
                return self
            }

            /// Sets the optional request headers attached to DRM license requests.
            @discardableResult
            public func setLicenseRequestHeaders(_ licenseRequestHeaders: [String: String]) -> Builder {
                self.licenseRequestHeaders = licenseRequestHeaders
                return self
            }

            /// Sets whether multi session is enabled.
            ///
            /// The default is `false` (multi session disabled).
            @discardableResult
            public func setMultiSession(_ multiSession: Bool) -> Builder {
                self.multiSession = multiSession
                return self
            }

            /// Sets whether to always use the default DRM license server URL even if the media specifies its own DRM
            /// license server URL.
            ///
            /// The default is `false`.
            @discardableResult
            public func setForceDefaultLicenseUrl(_ forceDefaultLicenseUrl: Bool) -> Builder {
                self.forceDefaultLicenseUrl = forceDefaultLicenseUrl
                return self
            }

            /// Sets whether clear samples within protected content should be played when keys for the encrypted part
            /// of the content have yet to be loaded.
            ///
            /// The default is `true`.
            @discardableResult
            public func setPlayClearContentWithoutKey(_ playClearContentWithoutKey: Bool) -> Builder {
                self.playClearContentWithoutKey = playClearContentWithoutKey
                return self
            }

            /// Sets whether a DRM session should be used for clear tracks of type `.video` and `.audio`.
            ///
            /// This method overrides what has been set by previously calling ``setForcedSessionTrackTypes(_:)``.
            ///
            /// The default is `false`.
            @discardableResult
            public func setForceSessionsForAudioAndVideoTracks(_ forceSessionsForAudioAndVideoTracks: Bool) -> Builder {
                setForcedSessionTrackTypes(forceSessionsForAudioAndVideoTracks ? [.video, .audio] : [])
            }

            /// Sets a list of track types for which to use a DRM session even when the tracks are in the clear.
            ///
            /// For the common case of using a DRM session for `.video` and `.audio`,
            /// ``setForceSessionsForAudioAndVideoTracks(_:)`` can be used.
            ///
            /// This method overrides what has been set by previously calling
            /// ``setForceSessionsForAudioAndVideoTracks(_:)``.
            ///
            /// The default is an empty list (i.e. DRM sessions are not forced for any track type).
            @discardableResult
            public func setForcedSessionTrackTypes(_ forcedSessionTrackTypes: [TrackType]) -> Builder {
                self.forcedSessionTrackTypes = forcedSessionTrackTypes
                return self
            }

            /// Sets the key set ID of the offline license.
            ///
            /// The key set ID identifies an offline license. The ID is required to query, renew or release an existing
            /// offline license.
            @discardableResult
            public func setKeySetId(_ keySetId: Data?) -> Builder {
                self.keySetId = keySetId
                return self
            }

            public func build() -> DrmConfiguration {
                DrmConfiguration(builder: self)
            }
        }
    }
}

// MARK: - AdsConfiguration

public extension MediaItem {
    /// Configuration for playing back linear ads with a media item.
    struct AdsConfiguration: Hashable, @unchecked Sendable {
        /// The ad tag URL to load.
        public let adTagUrl: URL

        /// An opaque identifier for ad playback state associated with this item, or `nil` if the combination of the
        /// ``MediaItem/Builder/setMediaId(_:)`` media ID and ``adTagUrl`` ad tag URL should be used as the ads
        /// identifier.
        ///
        /// Media items in the playlist that have the same ads identifier and ads loader share the same ad playback
        /// state. To resume ad playback when recreating the playlist on returning from the background, pass the same
        /// ads identifiers to the player.
        public let adsId: AnyHashable?

        fileprivate init(builder: Builder) {
            adTagUrl = builder.adTagUrl
            adsId = builder.adsId
        }

        /// Returns a ``Builder`` initialized with the values of this instance.
        public func buildUpon() -> Builder {
            Builder(adTagUrl: adTagUrl).setAdsId(adsId)
        }

        /// Builder for ``AdsConfiguration`` instances.
        public final class Builder {
            fileprivate var adTagUrl: URL
            fileprivate var adsId: AnyHashable?

            /// Constructs a new instance.
            ///
            /// - Parameter adTagUrl: The ad tag URL to load.
            public init(adTagUrl: URL) {
                self.adTagUrl = adTagUrl
            }

            /// Sets the ad tag URL to load.
            @discardableResult
            public func setAdTagUrl(_ adTagUrl: URL) -> Builder {
                self.adTagUrl = adTagUrl
                return self
            }

            /// Sets the ads identifier.
            ///
            /// See details on ``AdsConfiguration/adsId`` for how the ads identifier is used and how it's calculated if
            /// not explicitly set.
            @discardableResult
            public func setAdsId(_ adsId: AnyHashable?) -> Builder {
                self.adsId = adsId
                return self
            }

            public func build() -> AdsConfiguration {
                AdsConfiguration(builder: self)
            }
        }
    }
}

// MARK: - LocalConfiguration

public extension MediaItem {
    /// Properties for local playback.
    struct LocalConfiguration: Hashable, @unchecked Sendable {
        /// The URL.
        public let url: URL

        /// The optional MIME type of the item, or `nil` if unspecified.
        ///
        /// The MIME type can be used to disambiguate media items that have a URL which does not allow to infer the
        /// actual media type.
        public let mimeType: String?

        /// Optional ``DrmConfiguration`` for the media.
        public let drmConfiguration: DrmConfiguration?

        /// Optional ads configuration.
        public let adsConfiguration: AdsConfiguration?

        /// Optional stream keys by which the manifest is filtered.
        public let streamKeys: [StreamKey]

        /// Optional custom cache key (only used for progressive streams).
        public let customCacheKey: String?

        /// Optional subtitles to be sideloaded.
        public let subtitleConfigurations: [SubtitleConfiguration]

        /// Optional tag for custom attributes. The tag for the media source which will be published in the
        /// `Timeline` of the source as `Window.mediaItem`.
        public let tag: AnyHashable?

        /// Duration for image assets, or `.invalid` if unset.
        public let imageDuration: CMTime

        fileprivate init(
            url: URL,
            mimeType: String?,
            drmConfiguration: DrmConfiguration?,
            adsConfiguration: AdsConfiguration?,
            streamKeys: [StreamKey],
            customCacheKey: String?,
            subtitleConfigurations: [SubtitleConfiguration],
            tag: AnyHashable?,
            imageDuration: CMTime
        ) {
            self.url = url
            self.mimeType = mimeType
            self.drmConfiguration = drmConfiguration
            self.adsConfiguration = adsConfiguration
            self.streamKeys = streamKeys
            self.customCacheKey = customCacheKey
            self.subtitleConfigurations = subtitleConfigurations
            self.tag = tag
            self.imageDuration = imageDuration
        }
    }
}

// MARK: - LiveConfiguration

public extension MediaItem {
    /// Live playback configuration.
    struct LiveConfiguration: Hashable, Sendable {
        /// A live playback configuration with unset values, meaning media-defined default values will be used.
        public static let unset = Builder().build()

        /// Target offset from the live edge, or `.invalid` to use the media-defined default.
        public let targetOffset: CMTime

        /// The minimum allowed offset from the live edge, or `.invalid` to use the media-defined default.
        public let minOffset: CMTime

        /// The maximum allowed offset from the live edge, or `.invalid` to use the media-defined default.
        public let maxOffset: CMTime

        /// Minimum factor by which playback can be sped up, or `nil` to use the media-defined default.
        public let minPlaybackSpeed: Float?

        /// Maximum factor by which playback can be sped up, or `nil` to use the media-defined default.
        public let maxPlaybackSpeed: Float?

        fileprivate init(builder: Builder) {
            targetOffset = builder.targetOffset
            minOffset = builder.minOffset
            maxOffset = builder.maxOffset
            minPlaybackSpeed = builder.minPlaybackSpeed
            maxPlaybackSpeed = builder.maxPlaybackSpeed
        }

        /// Returns a ``Builder`` initialized with the values of this instance.
        public func buildUpon() -> Builder { Builder(liveConfiguration: self) }

        /// Builder for ``LiveConfiguration`` instances.
        public final class Builder {
            fileprivate var targetOffset: CMTime = .invalid
            fileprivate var minOffset: CMTime = .invalid
            fileprivate var maxOffset: CMTime = .invalid
            fileprivate var minPlaybackSpeed: Float?
            fileprivate var maxPlaybackSpeed: Float?

            /// Creates a new instance with default values.
            public init() {}

            fileprivate init(liveConfiguration: LiveConfiguration) {
                targetOffset = liveConfiguration.targetOffset
                minOffset = liveConfiguration.minOffset
                maxOffset = liveConfiguration.maxOffset
                minPlaybackSpeed = liveConfiguration.minPlaybackSpeed
                maxPlaybackSpeed = liveConfiguration.maxPlaybackSpeed
            }

            /// Sets the target live offset.
            ///
            /// Defaults to `.invalid`, indicating the media-defined default will be used.
            @discardableResult
            public func setTargetOffset(_ targetOffset: CMTime) -> Builder {
                self.targetOffset = targetOffset
                return self
            }

            /// Sets the minimum allowed live offset.
            ///
            /// Defaults to `.invalid`, indicating the media-defined default will be used.
            @discardableResult
            public func setMinOffset(_ minOffset: CMTime) -> Builder {
                self.minOffset = minOffset
                return self
            }

            /// Sets the maximum allowed live offset.
            ///
            /// Defaults to `.invalid`, indicating the media-defined default will be used.
            @discardableResult
            public func setMaxOffset(_ maxOffset: CMTime) -> Builder {
                self.maxOffset = maxOffset
                return self
            }

            /// Sets the minimum playback speed.
            ///
            /// Defaults to `nil`, indicating the media-defined default will be used.
            @discardableResult
            public func setMinPlaybackSpeed(_ minPlaybackSpeed: Float?) -> Builder {
                self.minPlaybackSpeed = minPlaybackSpeed
                return self
            }

            /// Sets the maximum playback speed.
            ///
            /// Defaults to `nil`, indicating the media-defined default will be used.
            @discardableResult
            public func setMaxPlaybackSpeed(_ maxPlaybackSpeed: Float?) -> Builder {
                self.maxPlaybackSpeed = maxPlaybackSpeed
                return self
            }

            /// Creates a ``LiveConfiguration`` with the values from this builder.
            public func build() -> LiveConfiguration {
                LiveConfiguration(builder: self)
            }
        }
    }
}

// MARK: - SubtitleConfiguration

public extension MediaItem {
    /// Properties for a text track.
    struct SubtitleConfiguration: Hashable, Sendable {
        /// The URL to the subtitle file.
        public let url: URL

        /// The optional MIME type of the subtitle file, or `nil` if unspecified.
        public let mimeType: String?

        /// The language.
        public let language: String?

        /// The selection flags.
        public let selectionFlags: SelectionFlags

        /// The role flags.
        public let roleFlags: RoleFlags

        /// The label.
        public let label: String?

        /// The ID of the subtitles. This will be propagated to the `id` of the subtitle track created from this
        /// configuration.
        public let id: String?

        fileprivate init(builder: Builder) {
            url = builder.url
            mimeType = builder.mimeType
            language = builder.language
            selectionFlags = builder.selectionFlags
            roleFlags = builder.roleFlags
            label = builder.label
            id = builder.id
        }

        /// Returns a ``Builder`` initialized with the values of this instance.
        public func buildUpon() -> Builder { Builder(subtitleConfiguration: self) }

        /// Builder for ``SubtitleConfiguration`` instances.
        public final class Builder {
            fileprivate var url: URL
            fileprivate var mimeType: String?
            fileprivate var language: String?
            fileprivate var selectionFlags = SelectionFlags()
            fileprivate var roleFlags = RoleFlags()
            fileprivate var label: String?
            fileprivate var id: String?

            /// Constructs an instance.
            ///
            /// - Parameter url: The URL to the subtitle file.
            public init(url: URL) {
                self.url = url
            }

            fileprivate init(subtitleConfiguration: SubtitleConfiguration) {
                url = subtitleConfiguration.url
                mimeType = subtitleConfiguration.mimeType
                language = subtitleConfiguration.language
                selectionFlags = subtitleConfiguration.selectionFlags
                roleFlags = subtitleConfiguration.roleFlags
                label = subtitleConfiguration.label
                id = subtitleConfiguration.id
            }

            /// Sets the URL to the subtitle file.
            @discardableResult
            public func setUrl(_ url: URL) -> Builder {
                self.url = url
                return self
            }

            /// Sets the MIME type.
            @discardableResult
            public func setMimeType(_ mimeType: String?) -> Builder {
                self.mimeType = mimeType
                return self
            }

            /// Sets the optional language of the subtitle file.
            @discardableResult
            public func setLanguage(_ language: String?) -> Builder {
                self.language = language
                return self
            }

            /// Sets the flags used for track selection.
            @discardableResult
            public func setSelectionFlags(_ selectionFlags: SelectionFlags) -> Builder {
                self.selectionFlags = selectionFlags
                return self
            }

            /// Sets the role flags. These are used for track selection.
            @discardableResult
            public func setRoleFlags(_ roleFlags: RoleFlags) -> Builder {
                self.roleFlags = roleFlags
                return self
            }

            /// Sets the optional label for this subtitle track.
            @discardableResult
            public func setLabel(_ label: String?) -> Builder {
                self.label = label
                return self
            }

            /// Sets the optional ID for this subtitle track.
            @discardableResult
            public func setId(_ id: String?) -> Builder {
                self.id = id
                return self
            }

            /// Creates a ``SubtitleConfiguration`` from the values of this builder.
            public func build() -> SubtitleConfiguration {
                SubtitleConfiguration(builder: self)
            }
        }
    }
}

// MARK: - ClippingConfiguration

public extension MediaItem {
    /// Optionally clips the media item to a custom start and end position.
    struct ClippingConfiguration: Hashable, Sendable {
        /// A clipping configuration with default values.
        public static let unset = Builder().build()

        /// The start position. This is a value larger than or equal to zero.
        public let startPosition: CMTime

        /// The end position. This is a value larger than or equal to zero, or `.positiveInfinity` to play to the end
        /// of the stream.
        public let endPosition: CMTime

        /// Whether the clipping of active media periods moves with a live window. If `false`, playback ends when it
        /// reaches ``endPosition``.
        public let relativeToLiveWindow: Bool

        /// Whether ``startPosition`` and ``endPosition`` are relative to the default position.
        public let relativeToDefaultPosition: Bool

        /// Whether the start point is guaranteed to be a key frame.
        public let startsAtKeyFrame: Bool

        /// Whether clipping to a non-zero start position in unseekable media is allowed.
        public let allowUnseekableMedia: Bool

        fileprivate init(builder: Builder) {
            startPosition = builder.startPosition
            endPosition = builder.endPosition
            relativeToLiveWindow = builder.relativeToLiveWindow
            relativeToDefaultPosition = builder.relativeToDefaultPosition
            startsAtKeyFrame = builder.startsAtKeyFrame
            allowUnseekableMedia = builder.allowUnseekableMedia
        }

        /// Returns a ``Builder`` initialized with the values of this instance.
        public func buildUpon() -> Builder { Builder(clippingConfiguration: self) }

        /// Builder for ``ClippingConfiguration`` instances.
        public final class Builder {
            fileprivate var startPosition: CMTime = .zero
            fileprivate var endPosition: CMTime = .positiveInfinity
            fileprivate var relativeToLiveWindow = false
            fileprivate var relativeToDefaultPosition = false
            fileprivate var startsAtKeyFrame = false
            fileprivate var allowUnseekableMedia = false

            /// Creates a new instance with default values.
            public init() {}

            fileprivate init(clippingConfiguration: ClippingConfiguration) {
                startPosition = clippingConfiguration.startPosition
                endPosition = clippingConfiguration.endPosition
                relativeToLiveWindow = clippingConfiguration.relativeToLiveWindow
                relativeToDefaultPosition = clippingConfiguration.relativeToDefaultPosition
                startsAtKeyFrame = clippingConfiguration.startsAtKeyFrame
                allowUnseekableMedia = clippingConfiguration.allowUnseekableMedia
            }

            /// Sets the optional start position which must be a value larger than or equal to zero (Default: zero).
            @discardableResult
            public func setStartPosition(_ startPosition: CMTime) -> Builder {
                precondition(startPosition >= .zero)
                self.startPosition = startPosition
                return self
            }

            /// Sets the optional end position which must be a value larger than or equal to zero, or
            /// `.positiveInfinity` to end when playback reaches the end of media (Default: `.positiveInfinity`).
            @discardableResult
            public func setEndPosition(_ endPosition: CMTime) -> Builder {
                precondition(endPosition.isPositiveInfinity || endPosition >= .zero)
                self.endPosition = endPosition
                return self
            }

            /// Sets whether the start/end positions should move with the live window for live streams. If `false`,
            /// live streams end when playback reaches the end position in live window seen when the media is first
            /// loaded (Default: `false`).
            @discardableResult
            public func setRelativeToLiveWindow(_ relativeToLiveWindow: Bool) -> Builder {
                self.relativeToLiveWindow = relativeToLiveWindow
                return self
            }

            /// Sets whether the start position and the end position are relative to the default position in the
            /// window (Default: `false`).
            @discardableResult
            public func setRelativeToDefaultPosition(_ relativeToDefaultPosition: Bool) -> Builder {
                self.relativeToDefaultPosition = relativeToDefaultPosition
                return self
            }

            /// Sets whether the start point is guaranteed to be a key frame. If `false`, the playback transition into
            /// the clip may not be seamless (Default: `false`).
            @discardableResult
            public func setStartsAtKeyFrame(_ startsAtKeyFrame: Bool) -> Builder {
                self.startsAtKeyFrame = startsAtKeyFrame
                return self
            }

            /// Sets whether clipping to a non-zero start position in unseekable media is allowed (Default: `false`).
            ///
            /// Note that this could be inefficient because a player needs to read and decode all samples from the
            /// beginning of the file and it should only be used if the clip start position is small and the entire
            /// data before the start position fits into memory.
            @discardableResult
            public func setAllowUnseekableMedia(_ allowUnseekableMedia: Bool) -> Builder {
                self.allowUnseekableMedia = allowUnseekableMedia
                return self
            }

            /// Returns a ``ClippingConfiguration`` instance initialized with the values of this builder.
            public func build() -> ClippingConfiguration {
                ClippingConfiguration(builder: self)
            }
        }
    }
}

// MARK: - RequestMetadata

public extension MediaItem {
    /// Metadata that helps the player to understand a playback request represented by a ``MediaItem``.
    ///
    /// This metadata is most useful for cases where playback requests are forwarded to other player instances and the
    /// player creating the request doesn't know the required ``LocalConfiguration`` for playback.
    struct RequestMetadata: Hashable, @unchecked Sendable {
        /// Empty request metadata.
        public static let empty = Builder().build()

        /// The URL of the requested media, or `nil` if not known or applicable.
        public let mediaUrl: URL?

        /// The search query for the requested media, or `nil` if not applicable.
        public let searchQuery: String?

        /// Optional extras.
        ///
        /// Given the complexities of checking the equality of two dictionaries, the contents of these extras are not
        /// considered in the equality or hash of the metadata: only whether there are any.
        public let extras: [String: Any]?

        fileprivate init(builder: Builder) {
            mediaUrl = builder.mediaUrl
            searchQuery = builder.searchQuery
            extras = builder.extras
        }

        /// Returns a ``Builder`` initialized with the values of this instance.
        public func buildUpon() -> Builder { Builder(requestMetadata: self) }

        public static func == (lhs: RequestMetadata, rhs: RequestMetadata) -> Bool {
            lhs.mediaUrl == rhs.mediaUrl
                && lhs.searchQuery == rhs.searchQuery
                && (lhs.extras == nil) == (rhs.extras == nil)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(mediaUrl)
            hasher.combine(searchQuery)
            hasher.combine(extras == nil)
        }

        /// Builder for ``RequestMetadata`` instances.
        public final class Builder {
            fileprivate var mediaUrl: URL?
            fileprivate var searchQuery: String?
            fileprivate var extras: [String: Any]?

            /// Constructs an instance.
            public init() {}

            fileprivate init(requestMetadata: RequestMetadata) {
                mediaUrl = requestMetadata.mediaUrl
                searchQuery = requestMetadata.searchQuery
                extras = requestMetadata.extras
            }

            /// Sets the URL of the requested media, or `nil` if not known or applicable.
            @discardableResult
            public func setMediaUrl(_ mediaUrl: URL?) -> Builder {
                self.mediaUrl = mediaUrl
                return self
            }

            /// Sets the search query for the requested media, or `nil` if not applicable.
            @discardableResult
            public func setSearchQuery(_ searchQuery: String?) -> Builder {
                self.searchQuery = searchQuery
                return self
            }

            /// Sets optional extras.
            @discardableResult
            public func setExtras(_ extras: [String: Any]?) -> Builder {
                self.extras = extras
                return self
            }

            /// Builds the request metadata.
            public func build() -> RequestMetadata {
                RequestMetadata(builder: self)
            }
        }
    }
}
