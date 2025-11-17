//
//  DecoderInputBuffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import Common
import CoreMedia.CMSampleBuffer

protocol Buffer: AnyObject {
    var flags: SampleFlags { get }
}

public final class DecoderInputBuffer: Buffer {
    var flags = SampleFlags()
    var time: Int64 = 0
    var size: Int = 0
    var isReady: Bool { data != nil }

    private var data: UnsafeMutableRawBufferPointer?

    init() {}

    func enqueue(buffer: UnsafeMutableRawBufferPointer) {
        precondition(!buffer.isEmpty)
        self.data = buffer
    }

    func dequeue() throws -> UnsafeMutableRawBufferPointer {
        guard let data, data.count > 0 else {
            throw BufferErrors.insufficientCapacity
        }

        return data
    }

    func dequeueOutputSpan(initializingWith initializer: (inout OutputRawSpan) throws -> Void) throws {
        guard let data, data.count > 0 else {
            throw BufferErrors.insufficientCapacity
        }

        var outputSpan = OutputRawSpan(buffer: data, initializedCount: 0)
        try initializer(&outputSpan)
    }

    func reset() {
        flags = []
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
