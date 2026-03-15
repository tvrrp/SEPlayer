//
//  MediaItem.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public struct MediaItem: Hashable, Sendable {
    public static let empty = MediaItem.Builder().build()

    public let mediaId: String
    public let localConfiguration: LocalConfiguration?
    public let liveConfiguration: LiveConfiguration?

    fileprivate init(mediaId: String, localConfiguration: LocalConfiguration?) {
        self.mediaId = mediaId
        self.localConfiguration = localConfiguration
        self.liveConfiguration = nil // TODO: liveConfig
    }

    public func buildUpon() -> Builder { Builder(mediaItem: self) }
}

public extension MediaItem {
    struct LocalConfiguration: Hashable, @unchecked Sendable {
        public let url: URL
        public let mimeType: String?
        public let tag: AnyHashable?
    }

    struct LiveConfiguration: Hashable, Sendable {
        public let targetOffsetMs: Int64
        public let minOffsetMs: Int64
        public let maxOffsetMs: Int64
        public let minPlaybackSpeed: Float
        public let maxPlaybackSpeed: Float

        init(
            targetOffsetMs: Int64 = .timeUnset,
            minOffsetMs: Int64 = .timeUnset,
            maxOffsetMs: Int64 = .timeUnset,
            minPlaybackSpeed: Float = 1.0,
            maxPlaybackSpeed: Float = 1.0
        ) {
            self.targetOffsetMs = targetOffsetMs
            self.minOffsetMs = minOffsetMs
            self.maxOffsetMs = maxOffsetMs
            self.minPlaybackSpeed = minPlaybackSpeed
            self.maxPlaybackSpeed = maxPlaybackSpeed
        }
    }
}

public extension MediaItem {
    final class Builder {
        var mediaId: String?
        var url: URL?
        var mimeType: String?
        var tag: AnyHashable?

        public init() {}

        fileprivate init(mediaItem: MediaItem) {
            mediaId = mediaItem.mediaId
            if let localConfiguration = mediaItem.localConfiguration {
                url = localConfiguration.url
                mimeType = localConfiguration.mimeType
                tag = localConfiguration.tag
            }
        }

        public func setMediaId(_ mediaId: String) -> Builder {
            self.mediaId = mediaId
            return self
        }

        public func setUrl(_ url: URL) -> Builder {
            self.url = url
            return self
        }

        public func setMimeType(_ mimeType: String) -> Builder {
            self.mimeType = mimeType
            return self
        }

        public func setTag(_ tag: AnyHashable?) -> Builder {
            self.tag = tag
            return self
        }

        public func build() -> MediaItem {
            var localConfiguration: LocalConfiguration?

            if let url {
                localConfiguration = LocalConfiguration(url: url, mimeType: mimeType, tag: tag)
            }

            let mediaId = if let mediaId { mediaId } else { String.defaultMediaId }
            return MediaItem(
                mediaId: mediaId,
                localConfiguration: localConfiguration
            )
        }
    }
}

private extension String {
    static let defaultMediaId: String = ""
}
