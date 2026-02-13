//
//  MediaSourceFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

public protocol MediaSourceFactory {
    func createMediaSource(mediaItem: MediaItem) -> MediaSource
}

struct DefaultMediaSourceFactory: MediaSourceFactory {
    let workQueue: Queue
    let loaderQueue: Queue
    let dataSourceFactory: DataSourceFactory
    let extractorsFactory: ExtractorsFactory

    init(workQueue: Queue, loaderQueue: Queue, dataSourceFactory: DataSourceFactory, extractorsFactory: ExtractorsFactory) {
        self.workQueue = workQueue
        self.loaderQueue = loaderQueue
        self.dataSourceFactory = dataSourceFactory
        self.extractorsFactory = extractorsFactory
    }

    func createMediaSource(mediaItem: MediaItem) -> MediaSource {
        // TODO: assert(workQueue.isCurrent())

        return ProgressiveMediaSource(
            queue: workQueue,
            loaderQueue: loaderQueue,
            mediaItem: mediaItem,
            dataSourceFactory: dataSourceFactory,
            extractorsFactory: extractorsFactory
        )
    }
}
