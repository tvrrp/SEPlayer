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

public class DecoderInputBuffer: Buffer {
    enum BufferReplacementMode {
        case disabled
        case enabled
    }

    var flags = SampleFlags()
    var format: Format?
    var timeUs: Int64 = 0
    var size: Int = 0

    let bufferReplacementMode: BufferReplacementMode
    private let paddingSize: Int
    private var buffer: UnsafeMutableRawBufferPointer?

    static func noDataBuffer() -> DecoderInputBuffer {
        DecoderInputBuffer(bufferReplacementMode: .disabled)
    }

    init(bufferReplacementMode: BufferReplacementMode, paddingSize: Int = 0) {
        self.bufferReplacementMode = bufferReplacementMode
        self.paddingSize = paddingSize
    }

    final func dequeue() throws -> UnsafeMutableRawBufferPointer {
        guard let buffer = try getData(), buffer.count > 0 else {
            throw BufferErrors.insufficientCapacity
        }

        return buffer
    }

    final func ensureSpaceForWrite(_ size: Int) throws {
        let size = size + paddingSize
        if try getData() == nil {
            try createReplacementBuffer(requiredCapacity: size)
            return
        }

        guard let buffer = try getData() else { return }
        guard buffer.count < size else { return }

        try createReplacementBuffer(requiredCapacity: size)
    }

    func commitWrite(amount: Int) { size = amount }
    func getData() throws -> UnsafeMutableRawBufferPointer? { buffer }

    func clear() {
        flags = []
        timeUs = .zero
        size = 0
    }

    func createReplacementBuffer(requiredCapacity: Int) throws {
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

    enum BufferErrors: Error {
        case insufficientCapacity
        case allocationFailed
    }
}
