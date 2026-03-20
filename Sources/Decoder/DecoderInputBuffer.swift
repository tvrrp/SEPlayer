//
//  DecoderInputBuffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import SEPlayerCommon
import CoreMedia.CMSampleBuffer

public protocol Buffer: AnyObject {
    var flags: SampleFlags { get }
}

open class DecoderInputBuffer: Buffer {
    public enum BufferReplacementMode {
        case disabled
        case enabled
    }

    public var flags = SampleFlags()
    public var format: Format?
    public var time: CMSampleTimingInfo = .invalid
    public var size: Int = 0

    public let bufferReplacementMode: BufferReplacementMode
    private let paddingSize: Int
    private var buffer: UnsafeMutableRawBufferPointer?

    public static func noDataBuffer() -> DecoderInputBuffer {
        DecoderInputBuffer(bufferReplacementMode: .disabled)
    }

    public init(bufferReplacementMode: BufferReplacementMode, paddingSize: Int = 0) {
        self.bufferReplacementMode = bufferReplacementMode
        self.paddingSize = paddingSize
    }

    public final func dequeue() throws -> UnsafeMutableRawBufferPointer {
        guard let buffer = try getData(), buffer.count > 0 else {
            throw BufferErrors.insufficientCapacity
        }

        return buffer
    }

    public final func ensureSpaceForWrite(_ size: Int) throws {
        let size = size + paddingSize
        if try getData() == nil {
            try createReplacementBuffer(requiredCapacity: size)
            return
        }

        guard let buffer = try getData() else { return }
        guard buffer.count < size else { return }

        try createReplacementBuffer(requiredCapacity: size)
    }

    open func commitWrite(amount: Int) { size = amount }
    open func getData() throws -> UnsafeMutableRawBufferPointer? { buffer }

    open func clear() {
        flags = []
        time = .invalid
        size = 0
    }

    open func createReplacementBuffer(requiredCapacity: Int) throws {
        guard bufferReplacementMode == .enabled else {
            throw BufferErrors.allocationFailed
        }

        if let buffer {
            buffer.deallocate()
        }

        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: requiredCapacity)
        buffer.initialize(repeating: .zero)
        self.buffer = UnsafeMutableRawBufferPointer(buffer)
    }

    public enum BufferErrors: Error {
        case insufficientCapacity
        case allocationFailed
    }
}
