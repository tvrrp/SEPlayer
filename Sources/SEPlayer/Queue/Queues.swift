//
//  Queues.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Dispatch

enum Queues {
    static let loaderQueue: Queue = SignalQueue(name: "com.seplayer.loader.shared", qos: .userInitiated)
    static let mainQueue: Queue = SignalQueue.mainQueue()
    static let audioDecodeQueue: Queue = SignalQueue(name: "com.seplayer.audioDecodeQueue.shared", qos: .userInitiated)
    static let videoDecodeQueue: Queue = SignalQueue(name: "com.seplayer.videoDecodeQueue.shared", qos: .userInitiated)
    static let eventQueue: Queue = SignalQueue(name: "com.seplayer.eventQueue.shared", qos: .userInitiated)
}
