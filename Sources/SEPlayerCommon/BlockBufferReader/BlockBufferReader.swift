//
//  BlockBufferReader.swift
//  SEPlayer
//
//  Created by tvrrp on 18.05.2026.
//

import CoreMedia

public struct BlockBufferReader: Hashable {
    public var readerIndex: Int {
        Int(self._readerIndex)
    }

    public var readableBytes: Int {
        // this cannot under/overflow because both are positive and writer >= reader (checked on ingestion of bytes).
        Int(blockBuffer.dataLength &- self._readerIndex)
    }

    public var capacity: Int {
        blockBuffer.dataLength
    }

    public var blockBuffer: CMBlockBuffer
    var _readerIndex: Int

    public init() throws(BlockBufferError) {
        self.blockBuffer = try CMBlockBuffer()
        _readerIndex = .zero
    }

    public init(_ blockBuffer: CMBlockBuffer) {
        self.blockBuffer = blockBuffer
        _readerIndex = .zero
    }

    /// A reader of a copy of `bytes`.
    public init<Bytes: Collection<UInt8>>(bytes: Bytes) throws(BlockBufferError) {
        let bytes = Array(bytes)
        self.blockBuffer = try CMBlockBuffer()
        _readerIndex = .zero
        guard !bytes.isEmpty else { return }
        let copy = try CMBlockBuffer(length: bytes.count, flags: .assureMemoryNow)
        let status = bytes.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: copy, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw BlockBufferError(status: status) }
        blockBuffer = copy
    }

    public init(reader: sending BlockBufferReader, range: Range<Int>? = nil, permitEmptyReference: Bool = false) throws(BlockBufferError) {
        self.blockBuffer = try CMBlockBuffer()
        try blockBuffer.append(
            bufferReference: reader.blockBuffer,
            range: range ?? 0 ..< reader.blockBuffer.dataLength,
            flags: permitEmptyReference ? .permitEmptyReference : []
        )
        _readerIndex = .zero
    }

    /// The readable bytes.
    private var readableRange: Range<Int> {
        _readerIndex ..< blockBuffer.dataLength
    }

    public func withUnsafeReadableBlockBuffer<R>(_ body: (CMBlockBuffer) throws -> R) throws -> R {
        try body(CMBlockBuffer(bufferReference: blockBuffer, range: readableRange))
    }

    public func withUnsafeReadableBuffer<R>(
        makeContigiousWith allocator: CFAllocator? = nil,
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        if let allocator {
            return try blockBuffer.makeContiguous(range: readableRange, allocator: allocator).withContiguousStorage(body)
        }
        return try blockBuffer.withContiguousStorage(in: readableRange, body)
    }

    public func extend(with blockBuffer: CMBlockBuffer, permitEmptyReference: Bool = false) throws(BlockBufferError) {
        try self.blockBuffer.append(
            bufferReference: blockBuffer,
            flags: permitEmptyReference ? [.permitEmptyReference] : []
        )
    }

    public func extend(with reader: BlockBufferReader, permitEmptyReference: Bool = false) throws(BlockBufferError) {
        try extend(with: reader.blockBuffer, permitEmptyReference: permitEmptyReference)
    }

    @_specialize(where T == BlockBufferView)
    public func extend<T: Collection>(
        with data: T,
        permitEmptyReference: Bool = false
    ) throws where T.Element == UInt8 {
        let blockBuffer = try data.withContiguousStorageIfAvailable {
            let blockBuffer = try CMBlockBuffer(length: $0.count, flags: .assureMemoryNow)
            try blockBuffer.replaceDataBytes(with: UnsafeRawBufferPointer($0))
            return blockBuffer
        }
        guard let blockBuffer else { return }
        try extend(with: blockBuffer, permitEmptyReference: permitEmptyReference)
    }

    public mutating func clear() throws(BlockBufferError) {
        self.blockBuffer = try CMBlockBuffer()
        _readerIndex = .zero
    }

    /// Move the reader index forward by `offset` bytes.
    ///
    /// - warning: By contract the bytes between (including) `readerIndex` and (excluding) `writerIndex` must be
    ///            initialised, ie. have been written before. Also the `readerIndex` must always be less than or equal
    ///            to the `writerIndex`. Failing to meet either of these requirements leads to undefined behaviour.
    /// - Parameters:
    ///   - offset: The number of bytes to move the reader index forward by.
    public mutating func moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self._readerIndex + offset
        precondition(
            newIndex >= 0 && newIndex <= blockBuffer.dataLength,
            "new readerIndex: \(newIndex), expected: range(0, \(blockBuffer.dataLength))"
        )
        self._moveReaderIndex(to: newIndex)
    }

    /// Set the reader index to `offset`.
    ///
    /// - warning: By contract the bytes between (including) `readerIndex` and (excluding) `writerIndex` must be
    ///            initialised, ie. have been written before. Also the `readerIndex` must always be less than or equal
    ///            to the `writerIndex`. Failing to meet either of these requirements leads to undefined behaviour.
    /// - Parameters:
    ///   - offset: The offset in bytes to set the reader index to.
    public mutating func moveReaderIndex(to offset: Int) {
        precondition(
            offset >= 0 && offset <= blockBuffer.dataLength,
            "new readerIndex: \(offset), expected: range(0, \(blockBuffer.dataLength))"
        )
        self._moveReaderIndex(to: offset)
    }

    /// Read an integer off this `BlockBufferReader`, move the reader index forward by the integer's byte size and return the result.
    ///
    /// - Parameters:
    ///   - endianness: The endianness of the integer in this `BlockBufferReader` (defaults to big endian).
    ///   - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - Returns: An integer value deserialized from this `BlockBufferReader` or throws if there aren't enough bytes readable.
    @inlinable
    public mutating func readInt<T: FixedWidthInteger>(endianness: Endianness = .big, as: T.Type = T.self) throws -> T {
        let result = try self.getInt(at: self.readerIndex, endianness: endianness, as: T.self)
        self.moveReaderIndex(forwardBy: MemoryLayout<T>.size)
        return result
    }

    /// Get the integer at `index` from this `BlockBufferReader`. Does not move the reader index.
    /// The selected bytes must be readable or else `error` will be returned.
    ///
    /// - Parameters:
    ///   - index: The starting index of the bytes for the integer into the `BlockBufferReader`.
    ///   - endianness: The endianness of the integer in this `BlockBufferReader` (defaults to big endian).
    ///   - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - Returns: An integer value deserialized from this `BlockBufferReader` or `error` if the bytes of interest are not
    ///            readable.
    public func getInt<T: FixedWidthInteger>(
        at index: Int,
        endianness: Endianness = Endianness.big,
        as: T.Type = T.self
    ) throws -> T {
        let range = try rangeWithinReadableBytes(index: index, length: MemoryLayout<T>.size)
        let startIndex = range.startIndex + readerIndex

        if T.self == UInt8.self {
            assert(range.count == 1)
            // ok as CMBlockBuffer should always contain one byte at every index
            return try blockBuffer.withUnsafeMutableBlockBytes(at: startIndex) { ptr in
                unsafeBitCast(ptr[0], to: T.self)
            }
        }

        var value: T = 0
        try withUnsafeMutableBytes(of: &value) { valuePtr throws(BlockBufferError) in
            try blockBuffer.copyDataBytes(atOffset: startIndex, to: valuePtr)
        }

        return _toEndianness(value: value, endianness: endianness)
    }

    /// Returns the integer at the current reader index without advancing it.
    ///
    /// This method is equivalent to calling `getInteger(at: readerIndex, ...)`
    ///
    /// - Parameters:
    ///   - endianness: The endianness of the integer (defaults to big endian).
    ///   - as: The desired `FixedWidthInteger` type (optional parameter).
    /// - Returns: An integer value deserialized from this `BlockBufferReader` or throws if the bytes are not readable.
    public func peekInt<T: FixedWidthInteger>(
        endianness: Endianness = .big,
        as: T.Type = T.self
    ) throws -> T {
        try self.getInt(at: self.readerIndex, endianness: endianness, as: `as`)
    }

    /// Read `length` bytes off this `BlockBufferReader`, move the reader index forward by `length` bytes and return the result
    /// as `Data`.
    ///
    /// `BlockBufferReader` will use a heuristic to decide whether to copy the bytes or whether to reference `BlockBufferReader`'s
    /// `CMBlockBuffer` from the returned `Data` value. If you want manual control over the byte transferring
    /// behaviour, please use `readData(length:byteTransferStrategy:)`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `BlockBufferReader`.
    /// - returns: A `Data` value containing `length` bytes or error if there aren't at least `length` bytes readable.
    public mutating func readData(length: Int) throws -> Data {
        try self.readData(length: length, byteTransferStrategy: .automatic)
    }

    /// Read `length` bytes off this `BlockBufferReader`, move the reader index forward by `length` bytes and return the result
    /// as `Data`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `BlockBufferReader`.
    ///     - byteTransferStrategy: Controls how to transfer the bytes. See `ByteTransferStrategy` for an explanation
    ///                             of the options.
    /// - returns: A `Data` value containing `length` bytes or error if there aren't at least `length` bytes readable.
    public mutating func readData(length: Int, byteTransferStrategy: ByteTransferStrategy) throws -> Data {
        let result = try self.getData(at: self.readerIndex, length: length, byteTransferStrategy: byteTransferStrategy)
        self.moveReaderIndex(forwardBy: length)
        return result
    }

    /// Return `length` bytes starting at `index` and return the result as `Data`. This will not change the reader index.
    /// The selected bytes must be readable or error will be thrown.
    ///
    /// `BlockBufferReader` will use a heuristic to decide whether to copy the bytes or whether to reference `BlockBufferReader`'s
    /// `CMBlockBuffer` from the returned `Data` value. If you want manual control over the byte transferring
    /// behaviour, please use `getData(at:byteTransferStrategy:)`.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `BlockBufferReader`
    ///     - length: The number of bytes of interest
    /// - returns: A `Data` value containing the bytes of interest or error if the selected bytes are not readable.
    public func getData(at index: Int, length: Int) throws -> Data {
        try self.getData(at: index, length: length, byteTransferStrategy: .automatic)
    }

    /// Return `length` bytes starting at `index` and return the result as `Data`. This will not change the reader index.
    /// The selected bytes must be readable or else error will be thrown.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `BlockBufferReader`
    ///     - length: The number of bytes of interest
    ///     - byteTransferStrategy: Controls how to transfer the bytes. See `ByteTransferStrategy` for an explanation
    ///                             of the options.
    /// - returns: A `Data` value containing the bytes of interest or error if the selected bytes are not readable.
    public func getData(at index0: Int, length: Int, byteTransferStrategy: ByteTransferStrategy) throws -> Data {
        guard length >= 0,
              index0 >= self.readerIndex,
              index0 - self.readerIndex <= self.readableBytes - length else {
            throw BlockBufferReaderErrors(.outOfBounds)
        }

        let range = index0 ..< (index0 + length)
        let doCopy: Bool = switch byteTransferStrategy {
        case .copy:
            true
        case .noCopy:
            !blockBuffer.isContiguous(in: range)
        case .automatic:
            !blockBuffer.isContiguous(in: range) || length <= 256 * 1024
        }

        if doCopy {
            return try blockBuffer.dataBytes(in: range)
        } else {
            return try blockBuffer.withUnsafeMutableBlockBytes(at: index0) { ptr in
                precondition(
                    ptr.count >= length,
                    "noCopy requested but contiguous run at offset \(index0) is only \(ptr.count) bytes, need \(length)"
                )
                let storageRef = Unmanaged<CMBlockBuffer>.passRetained(blockBuffer)
                return Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                    count: Int(length),
                    deallocator: .custom { _, _ in storageRef.release() }
                )
            }
        }
    }

    /// Get `length` bytes starting at `index` and return the result as `[UInt8]`. This will not change the reader index.
    /// The selected bytes must be readable or else `error` will be returned.
    ///
    /// - Parameters:
    ///   - index: The starting index of the bytes of interest into the `BlockBufferReader`.
    ///   - length: The number of bytes of interest.
    /// - Returns: A `[UInt8]` value containing the bytes of interest or `error` if the bytes `BlockBufferReader` are not readable.
    public func getBytes(at index: Int, length: Int) throws -> [UInt8] {
        let range = try self.rangeWithinReadableBytes(index: index, length: length)
        let startIndex = range.startIndex + readerIndex
        let blockBufferRange = startIndex ..< startIndex + range.count

        if blockBuffer.isContiguous(in: blockBufferRange) {
            return try blockBuffer.withContiguousStorage(in: blockBufferRange) { ptr in
                [UInt8](ptr.bindMemory(to: UInt8.self))
            }
        } else {
            return try [UInt8](blockBuffer.dataBytes(in: blockBufferRange))
        }
    }

    /// Read `length` bytes off this `BlockBufferReader`, move the reader index forward by `length` bytes and return the result
    /// as `[UInt8]`.
    ///
    /// - Parameters:
    ///   - length: The number of bytes to be read from this `BlockBufferReader`.
    /// - Returns: A `[UInt8]` value containing `length` bytes or `error` if there aren't at least `length` bytes readable.
    public mutating func readBytes(length: Int) throws -> [UInt8] {
        let result = try self.getBytes(at: self.readerIndex, length: length)
        self.moveReaderIndex(forwardBy: length)
        return result
    }

    /// Get a `String` decoding `length` bytes starting at `index` with `encoding`. This will not change the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `BlockBufferReader`.
    ///     - length: The number of bytes of interest.
    ///     - encoding: The `String` encoding to be used.
    /// - returns: A `String` value containing the bytes of interest or `nil` if the selected bytes are not readable or
    ///            cannot be decoded with the given encoding.
    public func getString(at index: Int, length: Int, encoding: String.Encoding) -> String? {
        guard let data = try? self.getData(at: index, length: length) else {
            return nil
        }
        return String(data: data, encoding: encoding)
    }

    /// Read a `String` decoding `length` bytes with `encoding` from the `readerIndex`, moving the `readerIndex` appropriately.
    ///
    /// - parameters:
    ///     - length: The number of bytes to read.
    ///     - encoding: The `String` encoding to be used.
    /// - returns: A `String` value containing the bytes of interest or `nil` if the `BlockBufferReader` doesn't contain enough bytes, or
    ///     if those bytes cannot be decoded with the given encoding.
    public mutating func readString(length: Int, encoding: String.Encoding) -> String? {
        guard length <= self.readableBytes else {
            return nil
        }

        guard let string = self.getString(at: self.readerIndex, length: length, encoding: encoding) else {
            return nil
        }
        self.moveReaderIndex(forwardBy: length)
        return string
    }

    /// Returns a slice of size `length` bytes, starting at `index`. The `BlockBufferReader` this is invoked on and the
    /// `BlockBufferReader` returned will share the same underlying storage. However, the byte at `index` in this `BlockBufferReader`
    /// will correspond to index `0` in the returned `BlockBufferReader`.
    /// The `readerIndex` of the returned `BlockBufferReader` will be `0`.
    ///
    /// The selected bytes must be readable or else `error` will be thrown.
    ///
    /// - Parameters:
    ///   - index: The index the requested slice starts at.
    ///   - length: The length of the requested slice.
    /// - Returns: A `BlockBufferReader` containing the selected bytes as readable bytes or `error` if the selected bytes were
    ///            not readable in the initial `BlockBufferReader`.
    public func getSlice(at index: Int, length: Int) throws -> BlockBufferReader {
        guard index >= 0 && length >= 0 && index >= self.readerIndex else {
            throw BlockBufferReaderErrors(.outOfBounds)
        }

        return try BlockBufferReader(CMBlockBuffer(bufferReference: blockBuffer, range: index ..< (index + length)))
    }

    public mutating func readSlice(length: Int) throws -> BlockBufferReader {
        let slice = try getSlice(at: readerIndex, length: length)
        self.moveReaderIndex(forwardBy: length)
        return slice
    }

    func _toEndianness<T: FixedWidthInteger>(value: T, endianness: Endianness) -> T {
        switch endianness {
        case .little:
            value.littleEndian
        case .big:
            value.bigEndian
        }
    }

    func rangeWithinReadableBytes(index: Int, length: Int) throws -> Range<Int> {
        guard index >= self.readerIndex && length >= 0 else {
            throw BlockBufferReaderErrors(.outOfBounds)
        }

        // both these &-s are safe, they can't underflow because both left & right side are >= 0 (and index >= readerIndex)
        let indexFromReaderIndex = index &- self.readerIndex
        assert(indexFromReaderIndex >= 0)
        guard indexFromReaderIndex <= self.readableBytes &- length else {
            throw BlockBufferReaderErrors(.outOfBounds)
        }

        let upperBound = indexFromReaderIndex &+ length // safe, can't overflow, we checked it above.

        // uncheckedBounds is safe because `length` is >= 0, so the lower bound will always be lower/equal to upper
        return Range<Int>(uncheckedBounds: (lower: indexFromReaderIndex, upper: upperBound))
    }

    mutating func _moveReaderIndex(to newIndex: Int) {
        assert(newIndex >= 0 && newIndex <= blockBuffer.dataLength)
        self._readerIndex = newIndex
    }
}

public extension Data {
    init(buffer: BlockBufferReader) throws {
        self = try buffer.blockBuffer.dataBytes()
    }
}

extension BlockBufferReader {
    public enum ByteTransferStrategy: Sendable {
        /// Force a copy of the bytes.
        case copy

        /// Do not copy the bytes if at all possible. Not possible for a noncontiguous range
        case noCopy

        /// Use a heuristic to decide whether to copy the bytes or not.
        case automatic
    }
}

public final class BlockBufferReaderErrors: IOError, @unchecked Sendable {
    public enum Cause {
        /// The bytes asked for are not readable.
        case outOfBounds
    }

    public init(_ cause: Cause) {
        super.init(message: "\(cause)", cause: nil)
    }
}
