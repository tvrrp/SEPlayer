//
//  MediaSourceFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.DefaultMediaSourceFactory
//    androidx.media3.exoplayer.hls.HlsMediaSource.Factory
//    androidx.media3.exoplayer.source.ProgressiveMediaSource.Factory
//  Copyright (C) 2016, 2020 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import DataSource
import Extractor
import SEPlayerCommon

/// Makes the ``MediaSource`` of a ``MediaItem``.
public protocol MediaSourceFactory {
    func createMediaSource(mediaItem: MediaItem) -> MediaSource
}

/// A ``MediaSourceFactory`` that passes each item to the factory of its type: HLS for HLS items, by their MIME type
/// or the extension of their url, and progressive for the others.
public struct DefaultMediaSourceFactory: MediaSourceFactory {
    private let hlsMediaSourceFactory: MediaSourceFactory
    private let progressiveMediaSourceFactory: MediaSourceFactory

    /// - Parameters:
    ///   - hlsMediaSourceFactory: Makes the sources of HLS items.
    ///   - progressiveMediaSourceFactory: Makes the sources of the other items.
    public init(hlsMediaSourceFactory: MediaSourceFactory, progressiveMediaSourceFactory: MediaSourceFactory) {
        self.hlsMediaSourceFactory = hlsMediaSourceFactory
        self.progressiveMediaSourceFactory = progressiveMediaSourceFactory
    }

    /// Makes the factory of each type with its defaults and what the types share.
    ///
    /// - Parameters:
    ///   - workQueue: The queue of the player the sources play in.
    ///   - loaderQueue: The queue the sources load and extract media on.
    ///   - makeDataSourceFactory: Makes the data source factory of each media source.
    ///   - extractorsFactory: Makes the extractors of progressive media; by default, all the extractors there are,
    ///     with `subtitleParserFactory`.
    ///   - subtitleParserFactory: Parses subtitles into cues as they load.
    ///   - loadErrorHandlingPolicy: Decides about retries and fallbacks when loads fail.
    public init(
        workQueue: Queue,
        loaderQueue: Queue,
        makeDataSourceFactory: @escaping () -> DataSourceFactory,
        extractorsFactory: ExtractorsFactory? = nil,
        subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory(),
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy()
    ) {
        hlsMediaSourceFactory = HlsMediaSourceFactory(
            workQueue: workQueue,
            loaderQueue: loaderQueue,
            makeDataSourceFactory: makeDataSourceFactory,
            subtitleParserFactory: subtitleParserFactory,
            loadErrorHandlingPolicy: loadErrorHandlingPolicy
        )
        progressiveMediaSourceFactory = ProgressiveMediaSourceFactory(
            workQueue: workQueue,
            loaderQueue: loaderQueue,
            makeDataSourceFactory: makeDataSourceFactory,
            extractorsFactory: extractorsFactory
                ?? DefaultExtractorFactory(queue: loaderQueue, subtitleParserFactory: subtitleParserFactory),
            loadErrorHandlingPolicy: loadErrorHandlingPolicy
        )
    }

    public func createMediaSource(mediaItem: MediaItem) -> MediaSource {
        if Self.isHls(mediaItem) {
            return hlsMediaSourceFactory.createMediaSource(mediaItem: mediaItem)
        }
        return progressiveMediaSourceFactory.createMediaSource(mediaItem: mediaItem)
    }
}

/// A ``MediaSourceFactory`` of HLS media sources.
public struct HlsMediaSourceFactory: MediaSourceFactory {
    private let workQueue: Queue
    private let loaderQueue: Queue
    private let makeDataSourceFactory: () -> DataSourceFactory
    private let extractorFactory: HlsExtractorFactory
    private let subtitleParserFactory: SubtitleParserFactory
    private let decryptionMemoryPool: CMMemoryPool
    private let loadErrorHandlingPolicy: LoadErrorHandlingPolicy
    private let allowsChunklessPreparation: Bool

    /// - Parameters:
    ///   - workQueue: The queue of the player the sources play in.
    ///   - loaderQueue: The queue the sources load and extract media on.
    ///   - makeDataSourceFactory: Makes the data source factory of each media source.
    ///   - extractorFactory: Makes the extractors of segments; by default, with `subtitleParserFactory`.
    ///   - subtitleParserFactory: Parses subtitles into cues as they load.
    ///   - decryptionMemoryPool: The memory of decrypted segments.
    ///   - loadErrorHandlingPolicy: Decides about retries and fallbacks when loads fail.
    ///   - allowsChunklessPreparation: Whether chunkless preparation is allowed. If `true`, preparation without
    ///     segment loads is enabled for streams whose multivariant playlist gives enough information about their
    ///     formats.
    public init(
        workQueue: Queue,
        loaderQueue: Queue,
        makeDataSourceFactory: @escaping () -> DataSourceFactory,
        extractorFactory: HlsExtractorFactory? = nil,
        subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory(),
        decryptionMemoryPool: CMMemoryPool = CMMemoryPool(ageOutPeriod: 5),
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy(),
        allowsChunklessPreparation: Bool = true
    ) {
        self.workQueue = workQueue
        self.loaderQueue = loaderQueue
        self.makeDataSourceFactory = makeDataSourceFactory
        self.extractorFactory = extractorFactory
            ?? DefaultHlsExtractorFactory(queue: loaderQueue, subtitleParserFactory: subtitleParserFactory)
        self.subtitleParserFactory = subtitleParserFactory
        self.decryptionMemoryPool = decryptionMemoryPool
        self.loadErrorHandlingPolicy = loadErrorHandlingPolicy
        self.allowsChunklessPreparation = allowsChunklessPreparation
    }

    public func createMediaSource(mediaItem: MediaItem) -> MediaSource {
        HlsMediaSource(
            queue: workQueue,
            loaderQueue: loaderQueue,
            mediaItem: mediaItem,
            dataSourceFactory: makeDataSourceFactory(),
            decryptionMemoryPool: decryptionMemoryPool,
            extractorFactory: extractorFactory,
            subtitleParserFactory: subtitleParserFactory,
            allowChunklessPreparation: allowsChunklessPreparation,
            loadErrorHandlingPolicy: loadErrorHandlingPolicy
        )
    }
}

/// A ``MediaSourceFactory`` of progressive media sources, for media files read from start to end.
public struct ProgressiveMediaSourceFactory: MediaSourceFactory {
    private let workQueue: Queue
    private let loaderQueue: Queue
    private let makeDataSourceFactory: () -> DataSourceFactory
    private let extractorsFactory: ExtractorsFactory
    private let loadErrorHandlingPolicy: LoadErrorHandlingPolicy

    /// - Parameters:
    ///   - workQueue: The queue of the player the sources play in.
    ///   - loaderQueue: The queue the sources load and extract media on.
    ///   - makeDataSourceFactory: Makes the data source factory of each media source.
    ///   - extractorsFactory: Makes the extractors that read the files.
    ///   - loadErrorHandlingPolicy: Decides about retries when loads fail.
    public init(
        workQueue: Queue,
        loaderQueue: Queue,
        makeDataSourceFactory: @escaping () -> DataSourceFactory,
        extractorsFactory: ExtractorsFactory,
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy()
    ) {
        self.workQueue = workQueue
        self.loaderQueue = loaderQueue
        self.makeDataSourceFactory = makeDataSourceFactory
        self.extractorsFactory = extractorsFactory
        self.loadErrorHandlingPolicy = loadErrorHandlingPolicy
    }

    public func createMediaSource(mediaItem: MediaItem) -> MediaSource {
        ProgressiveMediaSource(
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
