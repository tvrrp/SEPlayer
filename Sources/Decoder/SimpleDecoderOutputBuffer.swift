//
//  SimpleDecoderOutputBuffer.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//

import CoreMedia
import SEPlayerCommon

open class SimpleDecoderOutputBuffer: DecoderOutputBuffer {
    public var sampleFlags: SampleFlags = []
    public var time = CMSampleTimingInfo.invalid
    public var skippedOutputBufferCount = 0
    public var shouldBeSkipped: Bool = false

    private let releaseCallback: ((SimpleDecoderOutputBuffer) -> Void)
    private let allocator = ByteBufferAllocator()
    private var data = ByteBuffer()

    public init(_ releaseCallback: @escaping (SimpleDecoderOutputBuffer) -> Void) {
        self.releaseCallback = releaseCallback
    }

    open func initBuffer(time: CMSampleTimingInfo, size: Int) -> ByteBuffer {
        self.time = time
        if data.capacity < size {
            data = allocator.buffer(capacity: size)
        }

        data.clear()
        return data
    }

    open func release() {
        releaseCallback(self)
    }

    open func clear() {
        sampleFlags = []
        time = .invalid
        skippedOutputBufferCount = 0
        shouldBeSkipped = false

        data.clear()
    }
}
