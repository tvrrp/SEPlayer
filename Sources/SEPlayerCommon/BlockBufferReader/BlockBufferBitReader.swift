//
//  BlockBufferBitReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

import CoreMedia
import Foundation

public struct BlockBufferBitReader: Hashable {
    /// The buffer being read. Shared with whatever this instance was created from, unless the
    /// range-taking initialisers were used.
    public var blockBuffer: CMBlockBuffer { reader.blockBuffer }

    /// The number of bits yet to be read.
    public var bitsLeft: Int {
        (byteLimit &- byteOffset) &* 8 &- bitOffset
    }

    /// The number of whole bytes yet to be read.
    public var bytesLeft: Int { bitsLeft >> 3 }

    /// The current bit offset. (`ParsableBitArray.getPosition()`)
    public var position: Int { byteOffset &* 8 &+ bitOffset }

    /// The current byte offset. Must only be read when the position is byte aligned.
    /// (`ParsableBitArray.getBytePosition()`)
    public var bytePosition: Int {
        precondition(bitOffset == 0, "BlockBufferBitReader: position \(position) is not byte aligned")
        return byteOffset
    }

    /// Whether the position sits on a byte boundary.
    public var isByteAligned: Bool { bitOffset == 0 }

    /// The limit, in bytes.
    public private(set) var byteLimit: Int

    // The offset within the buffer, stored as the current byte offset, and the bit offset within
    // that byte (from 0 to 7).
    @usableFromInline internal var byteOffset: Int
    @usableFromInline internal var bitOffset: Int

    internal var reader: BlockBufferReader

    // MARK: - Init

    /// Creates a new instance that initially has no backing data.
    public init() throws {
        self.reader = try BlockBufferReader()
        self.byteOffset = 0
        self.bitOffset = 0
        self.byteLimit = self.reader.blockBuffer.endIndex
    }

    /// Creates a new instance that wraps an existing `CMBlockBuffer`.
    ///
    /// - Parameters:
    ///   - blockBuffer: The buffer to wrap.
    ///   - limit: The limit in bytes. Defaults to the full length of `blockBuffer`.
    public init(_ blockBuffer: CMBlockBuffer, limit: Int? = nil) {
        let limit = limit ?? blockBuffer.endIndex
        precondition(
            limit >= 0 && limit <= blockBuffer.endIndex,
            "limit: \(limit), expected: range(0, \(blockBuffer.endIndex))"
        )
        self.reader = BlockBufferReader(blockBuffer)
        self.byteOffset = 0
        self.bitOffset = 0
        self.byteLimit = limit
    }

    /// Creates a new instance sharing storage with `reader`.
    ///
    /// Mirrors `ParsableBitArray.reset(ParsableByteArray)`: the limit becomes the end of the
    /// buffer and the position becomes `reader.readerIndex * 8`. Any modification of the underlying
    /// `CMBlockBuffer` is visible in both instances.
    public init(reader: BlockBufferReader) {
        var reader = reader
        let start = reader.readerIndex
        reader.moveReaderIndex(to: 0)
        self.reader = reader
        self.byteOffset = start
        self.bitOffset = 0
        self.byteLimit = reader.blockBuffer.endIndex
    }

    /// Creates a new instance backed by a fresh `CMBlockBuffer` referencing `range` of `reader`'s
    /// buffer. The position starts at zero.
    public init(reader: sending BlockBufferReader, range: Range<Int>) throws {
        self.reader = try BlockBufferReader(reader: reader, range: range)
        self.byteOffset = 0
        self.bitOffset = 0
        self.byteLimit = self.reader.blockBuffer.endIndex
    }

    /// Creates a new instance sharing storage, position and limit with `bitReader`.
    public init(bitReader: BlockBufferBitReader) {
        self = bitReader
    }

    /// Creates a new instance backed by a fresh `CMBlockBuffer` referencing `range` of
    /// `bitReader`'s buffer. The position starts at zero.
    public init(bitReader: sending BlockBufferBitReader, range: Range<Int>) throws {
        self.reader = try BlockBufferReader(reader: bitReader.reader, range: range)
        self.byteOffset = 0
        self.bitOffset = 0
        self.byteLimit = self.reader.blockBuffer.endIndex
    }

    // MARK: - Reset

    /// Updates the instance to wrap `blockBuffer`, and resets the position to zero.
    public mutating func reset(_ blockBuffer: CMBlockBuffer, limit: Int? = nil) {
        self = BlockBufferBitReader(blockBuffer, limit: limit)
    }

    /// Sets this instance's buffer, position and limit to match `reader`.
    /// Any modification of the underlying `CMBlockBuffer` is visible in both instances.
    public mutating func reset(reader: BlockBufferReader) {
        self = BlockBufferBitReader(reader: reader)
    }

    /// Drops the backing storage and resets the position and limit to zero.
    public mutating func clear() throws {
        self = try BlockBufferBitReader()
    }

    /// Appends `blockBuffer` by reference and extends the limit accordingly. The position is
    /// untouched.
    public mutating func extend(with blockBuffer: CMBlockBuffer, permitEmptyReference: Bool = false) throws {
        try reader.extend(with: blockBuffer, permitEmptyReference: permitEmptyReference)
        byteLimit = reader.blockBuffer.endIndex
    }

    // MARK: - Positioning

    /// Sets the current bit offset.
    public mutating func setPosition(_ position: Int) {
        byteOffset = position / 8
        bitOffset = position - (byteOffset * 8)
        assertValidOffset()
    }

    /// Skips a single bit.
    public mutating func skipBit() {
        bitOffset += 1
        if bitOffset == 8 {
            bitOffset = 0
            byteOffset += 1
        }
        assertValidOffset()
    }

    /// Skips bits and moves the current reading position forward.
    ///
    /// - Parameter numBits: The number of bits to skip. May be negative to move backwards.
    public mutating func skipBits(_ numBits: Int) {
        setPosition(position + numBits)
    }

    /// Aligns the position to the next byte boundary. Does nothing if the position is already
    /// aligned.
    public mutating func byteAlign() {
        guard bitOffset != 0 else { return }
        bitOffset = 0
        byteOffset += 1
        assertValidOffset()
    }

    // MARK: - Bit reads

    /// Reads a single bit.
    ///
    /// - Returns: Whether the bit is set.
    public mutating func readBit() throws -> Bool {
        guard bitsLeft >= 1 else { throw BlockBufferReaderErrors(.outOfBounds) }
        let returnValue = (try byte(at: byteOffset) & (0x80 >> bitOffset)) != 0
        skipBit()
        return returnValue
    }

    /// Reads up to 32 bits.
    ///
    /// - Parameter numBits: The number of bits to read.
    /// - Returns: An integer whose bottom `numBits` bits hold the read data. Unlike the Java
    ///            original the result is zero extended, so a 32 bit read never comes back negative.
    @discardableResult
    public mutating func readBits(_ numBits: Int) throws -> Int {
        Int(try readBits32(numBits))
    }

    /// Reads up to 64 bits into an arbitrary fixed width integer.
    ///
    /// - Parameters:
    ///   - numBits: The number of bits to read.
    ///   - as: The desired `FixedWidthInteger` type (optional parameter).
    /// - Returns: A value whose bottom `numBits` bits hold the read data, truncated to `T` if `T`
    ///            is narrower than `numBits`.
    @discardableResult
    public mutating func readBits<T: FixedWidthInteger>(_ numBits: Int, as: T.Type = T.self) throws -> T {
        precondition(numBits >= 0 && numBits <= 64, "numBits: \(numBits), expected: range(0, 64)")
        if numBits <= 32 {
            return T(truncatingIfNeeded: try readBits32(numBits))
        }
        let mostSignificant = try readBits32(numBits - 32)
        let leastSignificant = try readBits32(32)
        return T(truncatingIfNeeded: (UInt64(mostSignificant) << 32) | UInt64(leastSignificant))
    }

    /// Reads up to 64 bits. Bit-for-bit equivalent of `ParsableBitArray.readBitsToLong`, including
    /// the sign of a full 64 bit read.
    @discardableResult
    public mutating func readBitsToLong(_ numBits: Int) throws -> Int64 {
        Int64(bitPattern: try readBits(numBits, as: UInt64.self))
    }

    /// Returns the next `numBits` bits without moving the position.
    public func peekBits<T: FixedWidthInteger>(_ numBits: Int, as: T.Type = T.self) throws -> T {
        var copy = self
        return try copy.readBits(numBits, as: T.self)
    }

    /// Reads `numBits` bits into `buffer`.
    ///
    /// - Parameters:
    ///   - buffer: The destination. The trailing `numBits % 8` bits are written into the most
    ///     significant bits of the last modified byte. The remaining ones are unmodified.
    ///   - offset: The offset in `buffer` at which the read data should be written.
    ///   - numBits: The number of bits to read.
    public mutating func readBits(into buffer: UnsafeMutableRawBufferPointer, offset: Int, numBits: Int) throws {
        precondition(numBits >= 0, "numBits: \(numBits), expected: >= 0")
        precondition(
            offset >= 0 && offset + (numBits + 7) / 8 <= buffer.count,
            "destination of \(buffer.count) bytes is too small for \(numBits) bits at offset \(offset)"
        )
        guard numBits <= bitsLeft else { throw BlockBufferReaderErrors(.outOfBounds) }
        guard numBits > 0 else { return }

        // Whole bytes.
        let to = offset + (numBits >> 3)
        for index in offset..<to {
            if bitOffset == 0 {
                // Unlike the Java original we do not touch `data[byteOffset + 1]` here: the JVM
                // version reads a byte it then shifts entirely away, which makes an aligned read of
                // the final byte overrun the array.
                buffer[index] = try byte(at: byteOffset)
                byteOffset += 1
            } else {
                let high = try byte(at: byteOffset)
                byteOffset += 1
                let low = try byte(at: byteOffset)
                buffer[index] = (high << bitOffset) | (low >> (8 - bitOffset))
            }
        }

        // Trailing bits.
        let trailingBits = numBits & 7
        guard trailingBits != 0 else {
            assertValidOffset()
            return
        }
        // Set bits that are going to be overwritten to 0.
        buffer[to] &= 0xFF >> trailingBits
        if bitOffset + trailingBits > 8 {
            // We read the rest of the current byte and advance.
            let current = try byte(at: byteOffset)
            buffer[to] |= current << bitOffset
            byteOffset += 1
            bitOffset -= 8
        }
        bitOffset += trailingBits
        let last = try byte(at: byteOffset)
        buffer[to] |= (last >> (8 - bitOffset)) << (8 - trailingBits)
        if bitOffset == 8 {
            bitOffset = 0
            byteOffset += 1
        }
        assertValidOffset()
    }

    /// Reads `numBits` bits into `buffer`.
    public mutating func readBits(into buffer: inout [UInt8], offset: Int = 0, numBits: Int) throws {
        try buffer.withUnsafeMutableBytes { pointer in
            try readBits(into: pointer, offset: offset, numBits: numBits)
        }
    }

    /// Reads `numBits` bits into a freshly allocated, zero filled byte array of
    /// `ceil(numBits / 8)` bytes.
    public mutating func readBits(numBits: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: (numBits + 7) / 8)
        try readBits(into: &buffer, offset: 0, numBits: numBits)
        return buffer
    }

    // MARK: - Byte aligned reads

    /// Reads an integer, moving the position forward by the integer's byte size.
    /// Must only be called when the position is byte aligned.
    public mutating func readInt<T: FixedWidthInteger>(
        endianness: Endianness = .big,
        as: T.Type = T.self
    ) throws -> T {
        try checkByteAligned(length: MemoryLayout<T>.size)
        return try delegate { try $0.readInt(endianness: endianness, as: T.self) }
    }

    /// Returns the integer at the current position without moving it.
    /// Must only be called when the position is byte aligned.
    public func peekInt<T: FixedWidthInteger>(
        endianness: Endianness = .big,
        as: T.Type = T.self
    ) throws -> T {
        try checkByteAligned(length: MemoryLayout<T>.size)
        return try reader.getInt(at: byteOffset, endianness: endianness, as: T.self)
    }

    /// Returns the integer at absolute `index` without moving the position. The position does not
    /// need to be byte aligned.
    public func getInt<T: FixedWidthInteger>(
        at index: Int,
        endianness: Endianness = .big,
        as: T.Type = T.self
    ) throws -> T {
        try reader.getInt(at: index, endianness: endianness, as: T.self)
    }

    /// Reads the next `length` bytes. Must only be called when the position is byte aligned.
    public mutating func readBytes(length: Int) throws -> [UInt8] {
        try checkByteAligned(length: length)
        return try delegate { try $0.readBytes(length: length) }
    }

    /// Reads the next `length` bytes into `buffer`. Must only be called when the position is byte
    /// aligned.
    public mutating func readBytes(into buffer: inout [UInt8], offset: Int, length: Int) throws {
        try checkByteAligned(length: length)
        precondition(
            offset >= 0 && offset + length <= buffer.count,
            "destination of \(buffer.count) bytes is too small for \(length) bytes at offset \(offset)"
        )
        let bytes = try delegate { try $0.readBytes(length: length) }
        buffer.replaceSubrange(offset..<(offset + length), with: bytes)
    }

    /// Reads the next `length` bytes as `Data`. Must only be called when the position is byte
    /// aligned.
    public mutating func readData(
        length: Int,
        byteTransferStrategy: BlockBufferReader.ByteTransferStrategy = .automatic
    ) throws -> Data {
        try checkByteAligned(length: length)
        return try delegate { try $0.readData(length: length, byteTransferStrategy: byteTransferStrategy) }
    }

    /// Returns a `BlockBufferReader` over the next `length` bytes and moves the position past them.
    /// Must only be called when the position is byte aligned.
    ///
    /// Wrap the result in `BlockBufferBitReader(reader:)` to keep reading it as a bitstream.
    public mutating func readSlice(length: Int) throws -> BlockBufferReader {
        try checkByteAligned(length: length)
        return try delegate { try $0.readSlice(length: length) }
    }

    /// Skips the next `length` bytes. Must only be called when the position is byte aligned.
    public mutating func skipBytes(_ length: Int) throws {
        try checkByteAligned(length: length)
        byteOffset += length
        assertValidOffset()
    }

    /// Reads the next `length` bytes as a UTF-8 string. Must only be called when the position is
    /// byte aligned.
    public mutating func readBytesAsString(length: Int) throws -> String {
        String(decoding: try readBytes(length: length), as: UTF8.self)
    }

    /// Reads the next `length` bytes as a string in `encoding`. Must only be called when the
    /// position is byte aligned.
    public mutating func readBytesAsString(length: Int, encoding: String.Encoding) throws -> String? {
        String(data: try readData(length: length), encoding: encoding)
    }

    /// Reads a `String` decoding `length` bytes with `encoding`, moving the position appropriately.
    /// Must only be called when the position is byte aligned.
    public mutating func readString(length: Int, encoding: String.Encoding) -> String? {
        guard bitOffset == 0, length >= 0, length <= bytesLeft else { return nil }
        return delegate { $0.readString(length: length, encoding: encoding) }
    }

    // MARK: - Writes

    /// Overwrites `numBits` from this buffer using the `numBits` least significant bits from
    /// `value`. Bits are written in order from most significant to least significant. The position
    /// is advanced by `numBits`.
    ///
    /// - Parameters:
    ///   - value: The integer whose `numBits` least significant bits are written.
    ///   - numBits: The number of bits to write, at most 32.
    public mutating func putInt<T: FixedWidthInteger>(_ value: T, numBits: Int) throws {
        precondition(numBits >= 0 && numBits <= 32, "numBits: \(numBits), expected: range(0, 32)")
        guard numBits > 0 else { return }
        guard numBits <= bitsLeft else { throw BlockBufferReaderErrors(.outOfBounds) }

        var value = UInt32(truncatingIfNeeded: value)
        if numBits < 32 {
            value &= (UInt32(1) << numBits) - 1
        }

        var remainingBitsToWrite = numBits
        let firstByteWriteSize = min(8 - bitOffset, numBits)
        let firstByteRightPaddingSize = 8 - bitOffset - firstByteWriteSize
        let firstByteBitmask = (UInt32(0xFF00) >> bitOffset) | ((UInt32(1) << firstByteRightPaddingSize) - 1)
        let firstByteInputBits = value >> (numBits - firstByteWriteSize)
        try modifyByte(at: byteOffset) { current in
            UInt8(truncatingIfNeeded: (UInt32(current) & firstByteBitmask)
                | (firstByteInputBits << firstByteRightPaddingSize))
        }
        remainingBitsToWrite -= firstByteWriteSize

        var currentByteIndex = byteOffset + 1
        while remainingBitsToWrite > 8 {
            try setByte(UInt8(truncatingIfNeeded: value >> (remainingBitsToWrite - 8)), at: currentByteIndex)
            currentByteIndex += 1
            remainingBitsToWrite -= 8
        }

        if remainingBitsToWrite > 0 {
            let lastByteRightPaddingSize = 8 - remainingBitsToWrite
            let lastByteInput = value & ((UInt32(1) << remainingBitsToWrite) - 1)
            try modifyByte(at: currentByteIndex) { current in
                UInt8(truncatingIfNeeded: (UInt32(current) & ((UInt32(1) << lastByteRightPaddingSize) - 1))
                    | (lastByteInput << lastByteRightPaddingSize))
            }
        }

        skipBits(numBits)
    }

    // MARK: - Internals

    private mutating func readBits32(_ numBits: Int) throws -> UInt32 {
        guard numBits != 0 else { return 0 }
        precondition(numBits > 0 && numBits <= 32, "numBits: \(numBits), expected: range(0, 32)")
        guard numBits <= bitsLeft else { throw BlockBufferReaderErrors(.outOfBounds) }

        var returnValue: UInt32 = 0
        bitOffset += numBits
        while bitOffset > 8 {
            bitOffset -= 8
            let current = try byte(at: byteOffset)
            byteOffset += 1
            returnValue |= UInt32(current) << bitOffset
        }
        let current = try byte(at: byteOffset)
        returnValue |= UInt32(current) >> (8 - bitOffset)
        returnValue &= UInt32.max >> (32 - numBits)
        if bitOffset == 8 {
            bitOffset = 0
            byteOffset += 1
        }
        assertValidOffset()
        return returnValue
    }

    @inline(__always)
    private func byte(at index: Int) throws -> UInt8 {
        try reader.getInt(at: index, as: UInt8.self)
    }

    @inline(__always)
    private func setByte(_ value: UInt8, at index: Int) throws {
        try modifyByte(at: index) { _ in value }
    }

    @inline(__always)
    private func modifyByte(at index: Int, _ body: (UInt8) -> UInt8) throws {
        guard index >= 0, index < byteLimit else { throw BlockBufferReaderErrors(.outOfBounds) }
        try reader.blockBuffer._withUnsafeMutableBytes(atOffset: index) { pointer in
            precondition(!pointer.isEmpty, "empty contiguous run at offset \(index)")
            pointer[0] = body(pointer[0])
        }
    }

    /// Runs `body` with the internal reader positioned at `byteOffset`, then adopts whatever
    /// position the reader ended up at and re-pins it to zero.
    @inline(__always)
    private mutating func delegate<R>(_ body: (inout BlockBufferReader) throws -> R) rethrows -> R {
        reader.moveReaderIndex(to: byteOffset)
        defer {
            byteOffset = reader.readerIndex
            reader.moveReaderIndex(to: 0)
            assertValidOffset()
        }
        return try body(&reader)
    }

    @inline(__always)
    private func checkByteAligned(length: Int) throws {
        precondition(bitOffset == 0, "BlockBufferBitReader: position \(position) is not byte aligned")
        guard length >= 0, length <= bytesLeft else { throw BlockBufferReaderErrors(.outOfBounds) }
    }

    private func assertValidOffset() {
        // It is fine for the position to be at the end of the buffer, but no further.
        precondition(
            byteOffset >= 0 && (byteOffset < byteLimit || (byteOffset == byteLimit && bitOffset == 0)),
            "invalid position: byteOffset \(byteOffset), bitOffset \(bitOffset), limit \(byteLimit)"
        )
    }
}
