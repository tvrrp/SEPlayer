//
//  BlockBufferInputStream.swift
//  SEPlayer
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// An `InputStream` of the readable bytes of a ``BlockBufferReader``, which reads them in place, across its blocks.
///
/// The stream is synchronous: all its bytes are available once it is open.
final class BlockBufferInputStream: InputStream {
    private var reader: BlockBufferReader
    private var status = Stream.Status.notOpen
    private var error: Error?
    private weak var streamDelegate: StreamDelegate?

    override var streamStatus: Stream.Status { status }
    override var streamError: Error? { error }
    override var hasBytesAvailable: Bool { status == .open && reader.readableBytes > 0 }

    override var delegate: StreamDelegate? {
        get { streamDelegate }
        set { streamDelegate = newValue }
    }

    init(reader: BlockBufferReader) {
        self.reader = reader
        super.init(data: Data())
    }

    override func open() {
        status = .open
    }

    override func close() {
        status = .closed
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength length: Int) -> Int {
        guard status == .open else { return status == .atEnd ? 0 : -1 }
        let count = min(length, reader.readableBytes)
        guard count > 0 else {
            status = .atEnd
            return 0
        }
        do {
            let destination = UnsafeMutableRawBufferPointer(start: buffer, count: count)
            try reader.blockBuffer.copyDataBytes(atOffset: reader.readerIndex, to: destination)
        } catch {
            self.error = error
            status = .error
            return -1
        }
        reader.moveReaderIndex(forwardBy: count)
        return count
    }

    /// The bytes may be in several blocks, so there is no one buffer to hand out.
    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }

    // A synchronous stream has no events to schedule.
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}
