//
//  SEPlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import CoreMedia.CMSync

public protocol SEPlayer: Player {
    var clock: CMClock { get }
    var preloadConfiguration: PreloadConfiguration { get set }
    var seekParameters: SeekParameters { get set }
    var pauseAtTheEndOfMediaItem: Bool { get set }

    func set(mediaSources: [MediaSource])
    func set(mediaSources: [MediaSource], resetPosition: Bool)
    func set(mediaSources: [MediaSource], startMediaItemIndex: Int, startPositionMs: Int64)
    func set(mediaSource: MediaSource)
    func set(mediaSource: MediaSource, startPositionMs: Int64)
    func set(mediaSource: MediaSource, resetPosition: Bool)
    func append(mediaSource: MediaSource)
    func insert(mediaSource: MediaSource, at index: Int)
    func append(mediaSources: [MediaSource])
    func insert(mediaSources: [MediaSource], at index: Int)

    func set(shuffleOrder: ShuffleOrder)
}
