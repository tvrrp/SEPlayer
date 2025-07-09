//
//  DecoderInputBuffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import CoreMedia.CMSampleBuffer

protocol Buffer: AnyObject {
    var flags: SampleFlags { get }
}

public final class DecoderInputBuffer: Buffer {
    var flags = SampleFlags()
    var time: Int64 = 0
    var size: Int = 0
    var isReady: Bool { data != nil }

    private var data: UnsafeMutableRawPointer?

    init() {}

    func enqueue(buffer: UnsafeMutableRawPointer) {
        self.data = buffer
    }

    func dequeue() throws -> UnsafeMutableRawPointer {
        guard let data else {
            throw BufferErrors.insufficientCapacity
        }

        return data
    }

    func reset() {
        time = 0
        size = 0
        data = nil
    }

    enum BufferErrors: Error {
        case insufficientCapacity
    }
}

extension DecoderInputBuffer {
    var sampleTimings: CMSampleTimingInfo {
        CMSampleTimingInfo(
            duration: .zero,
            presentationTimeStamp: CMTime.from(microseconds: time),
            decodeTimeStamp: .zero
        )
    }
}
