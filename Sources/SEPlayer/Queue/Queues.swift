//
//  Queues.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

enum Queues {
    static let internalStateQueue: Queue = SignalQueue(name: "com.SEPlayer.state", qos: .userInitiated)
    static let workQueue: Queue = SignalQueue(name: "com.SEPlayer.work", qos: .userInitiated)
    static let extractorQueue: Queue = SignalQueue(name: "com.SEPlayer.extractor", qos: .userInitiated)
    static let loaderQueue: Queue = SignalQueue(name: "com.SEPlayer.loader", qos: .userInitiated)
    static let mainQueue: Queue = SignalQueue.mainQueue()
    static let videoDecoderQueue: Queue = SignalQueue(name: "com.SEPlayer.videoDecoder", qos: .userInitiated)
    static let audioDecoderQueue: Queue = SignalQueue(name: "com.SEPlayer.audioDecoder", qos: .userInitiated)
    static let playerOutputsQueue: Queue = SignalQueue(name: "com.SEPlayer.output", qos: .userInitiated)
}
