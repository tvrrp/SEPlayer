//
//  Allocation.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public final class Allocation {
    public let data: UnsafeMutableRawBufferPointer
    public let capacity: Int

    private let _buffer: UnsafeMutableBufferPointer<UInt8>

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        _buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity)
        _buffer.initialize(repeating: .zero)
        data = UnsafeMutableRawBufferPointer(_buffer)
    }

    public func writeBuffer(offset: Int, length: Int, buffer: UnsafeRawBufferPointer) {
        precondition(offset < capacity && offset + length <= capacity)
        _setBytes(buffer, offset: offset, length: length)
    }

    public func writeBytes<Bytes: Collection>(offset: Int, length: Int, buffer: Bytes) where Bytes.Element == UInt8 {
        precondition(offset < capacity && offset + length <= capacity)
        if buffer.withContiguousStorageIfAvailable({ bytes in
            _setBytes(UnsafeRawBufferPointer(bytes), offset: offset, length: length)
            return true
        }) != nil {
            // fast path, we've got access to the contiguous bytes
            return
        } else {
            return setSlowPath(bytes: buffer, at: offset, length: length)
        }
    }

    public func writeWithOutputRawSpan(
        offset: Int,
        initializingWith initializer: (_ span: inout OutputRawSpan) throws -> Void
    ) rethrows {
        var span = OutputRawSpan(buffer: data, initializedCount: offset)
        try initializer(&span)
    }

    private func _setBytes(_ bytes: UnsafeRawBufferPointer, offset: Int, length: Int) {
        let targetPtr = UnsafeMutableRawBufferPointer(rebasing: data[offset ..< capacity])
        targetPtr.copyBytes(from: bytes[0 ..< length])
    }

    private func setSlowPath<Bytes: Sequence>(bytes: Bytes, at offset: Int, length: Int) where Bytes.Element == UInt8 {
        // TODO: real fix
        var outIndex = 0
        let base = data.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)

        for b in bytes {
            if outIndex == length { break }
            base[outIndex] = b
            outIndex += 1
        }
    }

    deinit {
        _buffer.deinitialize()
        _buffer.deallocate()
    }
}
