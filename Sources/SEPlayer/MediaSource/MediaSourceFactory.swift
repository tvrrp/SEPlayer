//
//  MediaSourceFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import CoreMedia
import DataSource
import Extractor
import SEPlayerCommon

public protocol MediaSourceFactory {
    func createMediaSource(mediaItem: MediaItem) -> MediaSource
}

struct DefaultMediaSourceFactory: MediaSourceFactory {
    let workQueue: Queue
    let loaderQueue: Queue
    /// Makes the data source factory of a media source: its data sources share HTTP resources with each other, and
    /// with no other media source's.
    let makeDataSourceFactory: () -> DataSourceFactory
    let extractorsFactory: ExtractorsFactory
    /// The memory of decrypted HLS segments.
    let decryptionMemoryPool: CMMemoryPool
    let loadErrorHandlingPolicy: LoadErrorHandlingPolicy

    init(
        workQueue: Queue,
        loaderQueue: Queue,
        makeDataSourceFactory: @escaping () -> DataSourceFactory,
        extractorsFactory: ExtractorsFactory,
        decryptionMemoryPool: CMMemoryPool,
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy()
    ) {
        self.workQueue = workQueue
        self.loaderQueue = loaderQueue
        self.makeDataSourceFactory = makeDataSourceFactory
        self.extractorsFactory = extractorsFactory
        self.decryptionMemoryPool = decryptionMemoryPool
        self.loadErrorHandlingPolicy = loadErrorHandlingPolicy
    }

    func createMediaSource(mediaItem: MediaItem) -> MediaSource {
        // TODO: assert(workQueue.isCurrent())

        if Self.isHls(mediaItem) {
            return HlsMediaSource(
                queue: workQueue,
                loaderQueue: loaderQueue,
                mediaItem: mediaItem,
                dataSourceFactory: makeDataSourceFactory(),
                decryptionMemoryPool: decryptionMemoryPool,
                loadErrorHandlingPolicy: loadErrorHandlingPolicy
            )
        }

        return ProgressiveMediaSource(
            queue: workQueue,
            loaderQueue: loaderQueue,
            mediaItem: mediaItem,
            dataSourceFactory: makeDataSourceFactory(),
            extractorsFactory: extractorsFactory,
            loadErrorHandlingPolicy: loadErrorHandlingPolicy
        )
    }
}

private extension DefaultMediaSourceFactory {
    /// Whether the item is an HLS stream: by its MIME type, or by the extension of its url.
    static func isHls(_ mediaItem: MediaItem) -> Bool {
        guard let configuration = mediaItem.localConfiguration else {
            return false
        }
        if let mimeType = configuration.mimeType {
            return mimeType.caseInsensitiveCompare(MimeTypes.applicationM3U8.rawValue) == .orderedSame
                || mimeType.lowercased() == "application/vnd.apple.mpegurl"
        }
        // By the end of the path: a last component of just `.m3u8` has no extension for `URL`.
        let path = configuration.url.path.lowercased()
        return path.hasSuffix(".m3u8") || path.contains("format=m3u8")
    }
}
