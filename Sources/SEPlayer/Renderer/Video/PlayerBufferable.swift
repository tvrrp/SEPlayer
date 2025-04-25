//
//  PlayerBufferable.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

import CoreVideo

enum PlayerBufferableAction {
    case reset
    case restore
}

protocol PlayerBufferable: AnyObject {
    func prepare(for action: PlayerBufferableAction)
    func enqueue(_ buffer: CVPixelBuffer)
    func end()

    func equal(to other: PlayerBufferable) -> Bool
}

extension PlayerBufferable {
    func equal(to other: PlayerBufferable) -> Bool {
        self === other
    }
}
