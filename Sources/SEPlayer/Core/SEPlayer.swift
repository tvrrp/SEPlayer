//
//  SEPlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import CoreMedia
@_exported import SEPlayerCommon

public protocol SEPlayer: Player {
    var clock: SEClock { get }
    var timebase: CMTimebase { get }
    var preloadConfiguration: PreloadConfiguration { get set }
    var pauseAtTheEndOfMediaItem: Bool { get set }

    func set(mediaSources: [MediaSource])
    func set(mediaSources: [MediaSource], resetPosition: Bool)
    func set(mediaSources: [MediaSource], startMediaItemIndex: Int, startPosition: CMTime)
    func set(mediaSource: MediaSource)
    func set(mediaSource: MediaSource, startPosition: CMTime)
    func set(mediaSource: MediaSource, resetPosition: Bool)
    func append(mediaSource: MediaSource)
    func insert(mediaSource: MediaSource, at index: Int)
    func append(mediaSources: [MediaSource])
    func insert(mediaSources: [MediaSource], at index: Int)

    func set(shuffleOrder: ShuffleOrder)

    func addPeriodicTimeObserver(for interval: CMTime, queue: DispatchQueue, block: @escaping (CMTime) -> Void) throws -> AnyObject
    func addBoundaryTimeObserver(for times: [CMTime], queue: DispatchQueue, block: @escaping (CMTime) -> Void) throws -> AnyObject
    func removeTimeObserver(_ observer: AnyObject)

    func createMessage(handler: @escaping (_ messageType: Int, _ message: Any?) async -> Void) -> PlayerMessage
    func setVideoOutput(_ output: any VideoOutput)
    func removeVideoOutput(_ output: any VideoOutput)
}

public extension SEPlayer {
    func addPeriodicTimeObserver(for interval: CMTime) throws -> AsyncStream<CMTime> {
        let (stream, continuation) = AsyncStream<CMTime>.makeStream()
        let token = try addPeriodicTimeObserver(for: interval, queue: .main) { time in
            continuation.yield(time)
        }
        continuation.onTermination = { _ in
            self.removeTimeObserver(token)
        }
        return stream
    }

    func addBoundaryTimeObserver(for times: [CMTime]) throws -> AsyncStream<CMTime> {
        let (stream, continuation) = AsyncStream<CMTime>.makeStream()
        let token = try addBoundaryTimeObserver(for: times, queue: .main) { time in
            continuation.yield(time)
        }
        continuation.onTermination = { _ in
            self.removeTimeObserver(token)
        }
        return stream
    }
}
