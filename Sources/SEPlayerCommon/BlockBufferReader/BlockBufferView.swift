//
//  BlockBufferView.swift
//  SEPlayer
//
//  Created by tvrrp on 21.06.2026.
//

//public struct BlockBufferView: RandomAccessCollection {
//    public typealias Element = UInt8
//    public typealias Index = Int
//    public typealias SubSequence = BlockBufferView
//
//    @usableFromInline var _buffer: BlockBufferReader
//    @usableFromInline var _range: Range<Index>
//
//    @inlinable
//    internal init(buffer: BlockBufferReader, range: Range<Index>) {
//        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.capacity)
//        self._buffer = buffer
//        self._range = range
//    }
//
//    /// Creates a `ByteBufferView` from the readable bytes of the given `buffer`.
//    @inlinable
//    public init(_ buffer: BlockBufferReader) {
//        self = BlockBufferView(buffer: buffer, range: buffer.readerIndex..<buffer.writerIndex)
//    }
//
//    @inlinable
//    public var startIndex: Index {
//        self._range.lowerBound
//    }
//
//    @inlinable
//    public var endIndex: Index {
//        self._range.upperBound
//    }
//
//    @inlinable
//    public func index(after i: Index) -> Index {
//        i + 1
//    }
//
//    @inlinable
//    public var count: Int {
//        // Unchecked is safe here: Range enforces that upperBound is strictly greater than
//        // lower bound, and we guarantee that _range.lowerBound >= 0.
//        self._range.upperBound &- self._range.lowerBound
//    }
//
//    @inlinable
//    public subscript(position: Index) -> UInt8 {
//        get {
//            guard position >= self._range.lowerBound && position < self._range.upperBound else {
//                preconditionFailure("index \(position) out of range")
//            }
//            return try! self._buffer.getInt(at: position)  // range check above
//        }
//    }
//
//    @inlinable
//    public subscript(range: Range<Index>) -> ByteBufferView {
//        get {
//            BlockBufferView(buffer: self._buffer, range: range)
//        }
//    }
//}
