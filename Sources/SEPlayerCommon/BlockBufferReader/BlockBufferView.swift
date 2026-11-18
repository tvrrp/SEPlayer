//
//  BlockBufferView.swift
//  SEPlayer
//
//  Created by tvrrp on 21.06.2026.
//

import CoreMedia

public struct BlockBufferView: RandomAccessCollection {
    public typealias Element = UInt8
    public typealias Index = Int
    public typealias SubSequence = BlockBufferView

    var _buffer: BlockBufferReader
    var _range: Range<Index>

    init(buffer: BlockBufferReader, range: Range<Index>) {
        precondition(
            range.lowerBound >= 0
                && range.upperBound <= (buffer.readerIndex + buffer.readableBytes)
        )
        self._buffer = buffer
        self._range = range
    }

    /// Creates a `ByteBufferView` from the readable bytes of the given `buffer`.
    public init(_ buffer: BlockBufferReader) {
        self = BlockBufferView(
            buffer: buffer,
            range: buffer.readerIndex ..< (buffer.readerIndex + buffer.readableBytes)
        )
    }

    public var startIndex: Index {
        self._range.lowerBound
    }

    public var endIndex: Index {
        self._range.upperBound
    }

    public func index(after i: Index) -> Index {
        i + 1
    }

    public var count: Int {
        // Unchecked is safe here: Range enforces that upperBound is strictly greater than
        // lower bound, and we guarantee that _range.lowerBound >= 0.
        self._range.upperBound &- self._range.lowerBound
    }

    public subscript(position: Index) -> UInt8 {
        guard position >= self._range.lowerBound && position < self._range.upperBound,
              let byte = try? self._buffer.getInt(at: position, as: UInt8.self) else {
            preconditionFailure("index \(position) out of range")
        }
        return byte
    }

    public subscript(range: Range<Index>) -> BlockBufferView {
        BlockBufferView(buffer: self._buffer, range: range)
    }

    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
        do {
            // Copies only when the range spans blocks.
            return try _buffer.blockBuffer.withContiguousStorage(in: _range) {
                try body($0.assumingMemoryBound(to: UInt8.self))
            }
        } catch {
            return nil
        }
    }
}

public extension BlockBufferReader {
    var readableBytesView: BlockBufferView {
        BlockBufferView(self)
    }

    var bytesView: BlockBufferView {
        BlockBufferView(
            BlockBufferReader(self.blockBuffer)
        )
    }
}
