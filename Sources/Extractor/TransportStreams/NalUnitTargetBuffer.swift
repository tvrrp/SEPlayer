//
//  NalUnitTargetBuffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.08.2026.
//

import CoreMedia
import SEPlayerCommon

final class NalUnitTargetBuffer {
    private let targetType: NalUnitUtil.H264NalUnitType
    private let allocator: CFAllocator

    private var isFilling = false
    private(set) var isCompleted = false

    private(set) var nalBuffer: CMBlockBuffer
    private(set) var nalLength = 0

    init(targetType: NalUnitUtil.H264NalUnitType, initialCapacity: Int = 128, memoryPool: CMMemoryPool) throws {
        self.targetType = targetType
        self.allocator = CMMemoryPoolGetAllocator(memoryPool)
        nalBuffer = try CMBlockBuffer(
            length: 3 + initialCapacity,
            allocator: allocator,
            flags: .assureMemoryNow
        )
        // Initialize data with a start code in the first three bytes.
        try nalBuffer.withUnsafeMutableBytes(atOffset: 0) { destination in
            destination[0] = 0
            destination[1] = 0
            destination[2] = 1
        }
    }

    func reset() {
        isFilling = false
        isCompleted = false
    }

    func startNalUnit(type: Int) {
        precondition(!isFilling)
        isFilling = type == targetType.rawValue
        if isFilling {
            // Skip the three byte start code when writing data.
            nalLength = 3
            isCompleted = false
        }
    }

    /// Called to pass stream data. The data passed should not include the 3 byte start code.
    @_specialize(where T == BlockBufferView)
    func appendToNalUnit<T: Collection>(_ source: T) throws where T.Element == UInt8 {
        guard isFilling, source.count > 0 else { return }
        try ensureCapacity(nalLength + source.count)
        let copied = try source.withContiguousStorageIfAvailable {
            try nalBuffer[nalLength..<(nalLength + $0.count)]
                .replaceDataBytes(with: UnsafeRawBufferPointer($0))
            return $0.count
        }

        nalLength += copied ?? 0
    }

    @discardableResult
    func endNalUnit(discardPadding: Int) -> Bool {
        guard isFilling else { return false }
        nalLength -= discardPadding
        isFilling = false
        isCompleted = true
        return true
    }

    private func ensureCapacity(_ required: Int) throws {
        guard required > nalBuffer.dataLength else { return }
        let amountToGrow = required - nalBuffer.dataLength

        try nalBuffer.append(
            length: amountToGrow,
            allocator: allocator,
            flags: .assureMemoryNow
        )
    }
}
