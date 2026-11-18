//
//  NalUnitAccumulator.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.08.2026.
//

import CoreMedia
import SEPlayerCommon

final class NalUnitAccumulator {
    private static let lengthPrefixSize = 4
    private static let defaultCapacity = Int(getpagesize())

    private let allocator: CFAllocator
    private let ignoreNalTypes: [Int]

    private var buffer: CMBlockBuffer
    private var filling = false
    private var startOfNewNal = 0
    private var writePosition = 0
    /// Where committed samples are copied to.
    private let sampleMemory: SampleMemory

    init(memoryPool: CMMemoryPool, ignoreNalTypes: [Int]) throws {
        allocator = memoryPool.allocator
        self.ignoreNalTypes = ignoreNalTypes
        buffer = try CMBlockBuffer(length: Self.defaultCapacity, allocator: allocator)
        sampleMemory = SampleMemory(allocator: allocator, blockSize: 512 * 1024) // 512 KB
    }

    func startNalUnit(type: Int) throws {
        guard !ignoreNalTypes.contains(type) else {
            return
        }

        filling = true
        startOfNewNal = writePosition
        writePosition += Self.lengthPrefixSize
    }

    @_specialize(where T == BlockBufferView)
    func append<T: Collection>(_ source: T) throws where T.Element == UInt8 {
        guard filling, writePosition > 0, source.count > 0 else { return }
        try ensureCapacity(buffer: buffer, required: writePosition + source.count)
        let copied = try source.withContiguousStorageIfAvailable {
            try buffer.replaceDataBytes(with: UnsafeRawBufferPointer($0), atOffset: writePosition)
            return $0.count
        }

        writePosition += copied ?? 0
    }

    /// Backfills the reserved prefix of the unit that ended.
    ///
    /// - Parameter discardPadding: Bytes appended to the unit that belong to the start code of the next one.
    func finishNalUnit(discardPadding: Int = 0) throws {
        guard filling else { return }
        filling = false

        let payloadStart = startOfNewNal + Self.lengthPrefixSize
        writePosition = max(payloadStart, writePosition - discardPadding)
        let payloadLength = writePosition - payloadStart
        guard payloadLength > 0 else {
            // An empty unit, as the delimiter simulated at the end of the input: its prefix would be read as the
            // length of a unit that isn't there.
            writePosition = startOfNewNal
            return
        }
        var prefix = UInt32(payloadLength).bigEndian
        try withUnsafeBytes(of: &prefix) { source in
            try buffer.replaceDataBytes(with: source, atOffset: startOfNewNal)
        }
    }

    func commit() throws -> CMBlockBuffer? {
        guard writePosition > 0 else { return nil }
        let sample = try sampleMemory.copy(buffer, range: 0..<writePosition)
        writePosition = 0
        startOfNewNal = 0

        return sample
    }

    /// Discards everything accumulated so far, e.g. after a seek or a stream discontinuity.
    func reset() {
        filling = false
        startOfNewNal = 0
        writePosition = 0
    }

    private func ensureCapacity(buffer: CMBlockBuffer, required: Int) throws {
        guard required > buffer.dataLength else { return }
        var target = buffer.dataLength
        while target < required {
            target *= 2
        }

        try buffer.appendMemoryBlock(
            length: target,
            allocator: allocator,
            flags: .assureMemoryNow
        )
    }
}
