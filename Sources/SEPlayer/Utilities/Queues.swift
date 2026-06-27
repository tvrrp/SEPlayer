//
//  Queues.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import SEPlayerCommon

public enum Queues {
    static let loaderQueue: Queue = SignalQueue(name: "com.seplayer.loader.shared", qos: .userInitiated)
    static let mainQueue: Queue = SignalQueue.mainQueue()
    static let sharedVideoDecodeQueue: Queue = SignalQueue(name: "com.seplayer.videoDecodeQueue.shared", qos: .userInitiated)
    static let sharedAudioDecodeQueue: Queue = SignalQueue(name: "com.seplayer.audioDecodeQueue.shared", qos: .userInitiated)
    static let eventQueue: Queue = SignalQueue(name: "com.seplayer.eventQueue.shared", qos: .userInitiated)
}
