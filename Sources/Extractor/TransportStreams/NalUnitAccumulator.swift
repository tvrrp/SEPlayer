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

    init(memoryPool: CMMemoryPool, ignoreNalTypes: [Int]) throws {
        allocator = CMMemoryPoolGetAllocator(memoryPool)
        self.ignoreNalTypes = ignoreNalTypes
        buffer = try CMBlockBuffer(length: Self.defaultCapacity, allocator: allocator)
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
            try buffer[writePosition...].replaceDataBytes(with: UnsafeRawBufferPointer($0))
            return $0.count
        }

        writePosition += copied ?? 0
    }

    /// Backfills the reserved prefix and returns a reference sized to the unit.
    func finishNalUnit() throws {
        guard filling else { return }
        filling = false

        let payloadLength = writePosition - startOfNewNal - Self.lengthPrefixSize
        guard payloadLength > 0 else { return }
        var prefix = UInt32(payloadLength).bigEndian
        try withUnsafeBytes(of: &prefix) { source in
            try buffer[startOfNewNal..<(startOfNewNal + Self.lengthPrefixSize)].replaceDataBytes(with: source)
        }
    }

    func commit() throws -> CMBlockBuffer? {
        guard writePosition > 0 else { return nil }
        let buffer = try buffer[0...writePosition].makeContiguous(
            allocator: allocator,
            flags: [.assureMemoryNow, .alwaysCopyData]
        )
        writePosition = 0
        startOfNewNal = 0

        return buffer
    }

    private func ensureCapacity(buffer: CMBlockBuffer, required: Int) throws {
        guard required > buffer.dataLength else { return }
        var target = buffer.dataLength
        while target < required {
            target *= 2
        }

        try buffer.append(
            length: target - buffer.dataLength,
            allocator: allocator,
            flags: .assureMemoryNow
        )
    }
}
