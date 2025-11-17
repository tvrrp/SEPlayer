//
//  PlayerBufferable.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

import AVFoundation

public enum PlayerBufferableAction {
    case reset
    case restore
}

public protocol PlayerBufferable: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    func setControlTimebase(_ timebase: CMTimebase?)
    func prepare(for action: PlayerBufferableAction)
    func requestMediaDataWhenReady(on queue: Queue, block: @escaping () -> Void)
    func stopRequestingMediaData()
    func enqueue(_ buffer: CMSampleBuffer, format: Format?)
    func end()

    func equal(to other: PlayerBufferable) -> Bool
}

public extension PlayerBufferable {
    func equal(to other: PlayerBufferable) -> Bool {
        self === other
    }
}
