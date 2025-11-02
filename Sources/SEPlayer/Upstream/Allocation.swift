//
//  Allocation.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public final class Allocation {
    let data: UnsafeMutableRawBufferPointer
    let capacity: Int

    private let _buffer: UnsafeMutableBufferPointer<UInt8>

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        _buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity)
        _buffer.initialize(repeating: .zero)
        data = UnsafeMutableRawBufferPointer(_buffer)
    }

    public func writeBuffer(offset: Int, lenght: Int, buffer: UnsafeRawBufferPointer) {
        precondition(offset < capacity && offset + lenght <= capacity)
        _setBytes(buffer, offset: offset, lenght: lenght)
    }

    public func writeBytes<Bytes: Collection>(offset: Int, lenght: Int, buffer: Bytes) where Bytes.Element == UInt8 {
        precondition(offset < capacity && offset + lenght <= capacity)
        if buffer.withContiguousStorageIfAvailable({ bytes in
            _setBytes(UnsafeRawBufferPointer(bytes), offset: offset, lenght: lenght)
            return true
        }) != nil {
            // fast path, we've got access to the contiguous bytes
            return
        } else {
            return setSlowPath(bytes: buffer, at: offset, lenght: lenght)
        }
    }

    private func _setBytes(_ bytes: UnsafeRawBufferPointer, offset: Int, lenght: Int) {
        let targetPtr = UnsafeMutableRawBufferPointer(fastRebase: data[offset..<capacity])
        targetPtr.copyBytes(from: bytes[0..<lenght])
    }

    private func setSlowPath<Bytes: Sequence>(bytes: Bytes, at index: Int, lenght: Int) where Bytes.Element == UInt8 {
        fatalError() // TODO: fix
    }

    deinit {
        _buffer.deinitialize()
        _buffer.deallocate()
    }
}
