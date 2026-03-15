//
//  SimpleDecoderOutputBuffer.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//

import SEPlayerCommon

open class SimpleDecoderOutputBuffer: DecoderOutputBuffer {
    public var sampleFlags: SampleFlags = []
    public var timeUs: Int64 = 0
    public var skippedOutputBufferCount: Int = 0
    public var shouldBeSkipped: Bool = false

    private let releaseCallback: ((SimpleDecoderOutputBuffer) -> Void)
    private let allocator = ByteBufferAllocator()
    private var data = ByteBuffer()

    public init(_ releaseCallback: @escaping (SimpleDecoderOutputBuffer) -> Void) {
        self.releaseCallback = releaseCallback
    }

    open func initBuffer(timeUs: Int64, size: Int) -> ByteBuffer {
        self.timeUs = timeUs
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
        timeUs = 0
        skippedOutputBufferCount = 0
        shouldBeSkipped = false

        data.clear()
    }
}
