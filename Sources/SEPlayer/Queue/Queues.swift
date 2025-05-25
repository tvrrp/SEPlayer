//
//  Queues.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

enum Queues {
    static let loaderQueue: Queue = SignalQueue(name: "com.SEPlayer.loader", qos: .userInitiated)
    static let mainQueue: Queue = SignalQueue.mainQueue()
    static let audioQueue: Queue = SignalQueue(name: "com.SEPlayer.audioQueue", qos: .userInitiated)
}
