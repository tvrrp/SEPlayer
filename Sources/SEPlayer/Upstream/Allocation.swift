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

    var bytes: RawSpan {
        @_lifetime(borrow self)
        borrowing get {
            _overrideLifetime(RawSpan(_unsafeBytes: data), borrowing: self)
        }
    }

//    var mutableBytes: MutableRawSpan {
//        @_lifetime(self)
//        get {
//            _overrideLifetime(MutableRawSpan(_unsafeBytes: data), mutating: self)
//        }
//    }

    var span: Span<UInt8> {
        @_lifetime(borrow self)
        borrowing get {
            _overrideLifetime(Span(_unsafeElements: _buffer), borrowing: self)
        }
    }

//    var mutableSpan: MutableSpan<UInt8> {
//        @_lifetime(self)
//        get {
//            _overrideLifetime(MutableSpan(_unsafeElements: _buffer), mutating: self)
//        }
//    }

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

    func writeWithOutputRawSpan(
        offset: Int,
        initializingWith initializer: (_ span: inout OutputRawSpan) throws -> Void
    ) rethrows -> Void {
        var span = OutputRawSpan(buffer: data, initializedCount: offset)
        try initializer(&span)
    }

    private func _setBytes(_ bytes: UnsafeRawBufferPointer, offset: Int, lenght: Int) {
        let targetPtr = UnsafeMutableRawBufferPointer(rebasing: data[offset..<capacity])
        targetPtr.copyBytes(from: bytes[0..<lenght])
    }

    private func setSlowPath<Bytes: Sequence>(bytes: Bytes, at offset: Int, lenght: Int) where Bytes.Element == UInt8 {
        // TODO: real fix
        var outIndex = 0
        let base = data.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)

        for b in bytes {
            if outIndex == lenght { break }
            base[outIndex] = b
            outIndex += 1
        }
    }

    deinit {
        _buffer.deinitialize()
        _buffer.deallocate()
    }
}
