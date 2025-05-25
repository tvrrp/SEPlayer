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

    func createMediaSource(mediaItem: MediaItem) -> MediaSource {
        assert(workQueue.isCurrent())

        return ProgressiveMediaSource(
            queue: workQueue,
            loaderQueue: loaderQueue,
            mediaItem: mediaItem,
            dataSourceFactory: dataSourceFactory,
            extractorsFactory: extractorsFactory)
    }
}
