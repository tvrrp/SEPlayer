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
    let loaderSyncActor: PlayerActor
    let dataSourceFactory: DataSourceFactory
    let extractorsFactory: ExtractorsFactory

    init(workQueue: Queue, loaderSyncActor: PlayerActor, dataSourceFactory: DataSourceFactory, extractorsFactory: ExtractorsFactory) {
        self.workQueue = workQueue
        self.loaderSyncActor = loaderSyncActor
        self.dataSourceFactory = dataSourceFactory
        self.extractorsFactory = extractorsFactory
    }

    func createMediaSource(mediaItem: MediaItem) -> MediaSource {
        // TODO: assert(workQueue.isCurrent())

        return ProgressiveMediaSource(
            queue: workQueue,
            loaderSyncActor: loaderSyncActor,
            mediaItem: mediaItem,
            dataSourceFactory: dataSourceFactory,
            extractorsFactory: extractorsFactory
        )
    }
}
