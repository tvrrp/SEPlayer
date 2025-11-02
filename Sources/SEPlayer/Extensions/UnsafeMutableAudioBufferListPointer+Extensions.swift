//
//  UnsafeMutableAudioBufferListPointer+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.11.2025.
//

import CoreAudio

extension UnsafeMutableAudioBufferListPointer {
    init(capacity: Int, individualBufferSize: Int) {
        self = AudioBufferList.allocate(maximumBuffers: capacity)

        for index in 0..<self.count {
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: individualBufferSize)
            self[index].mData = UnsafeMutableRawPointer(buffer.baseAddress)
        }
    }

    func deallocateAllBuffers() {
        forEach { $0.mData?.deallocate() }
        unsafeMutablePointer.deallocate()
    }
}
