//
//  SampleDataQueue2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.07.2026.
//

import CoreMedia
import SEPlayerCommon

final class SampleDataQueue2 {
    private let queue: Queue
    private let lock: UnfairLock
//    private let rwLock: RWLock

    // TODO: RWLock
    private var masterBuffer: CMBlockBuffer
    // TODO: Atomics
    private var baseOffset: Int
    private var totalBytesWritten: Int

    init(queue: Queue) throws {
        self.queue = queue
        lock = UnfairLock()
//        rwLock = RWLock()
        masterBuffer = try CMBlockBuffer()
        baseOffset = 0
        totalBytesWritten = 0
    }

    func reset() throws {
        assert(queue.isCurrent())
        let masterBuffer = try CMBlockBuffer()
        lock.withLock { self.masterBuffer = masterBuffer }

        lock.withLock {
            baseOffset = 0
            totalBytesWritten = 0
        }
    }

    func discardUpstreamSampleBytes(totalBytesWritten: Int) throws {
        assert(queue.isCurrent())
        let (baseOffset, totalBytesWritten) = lock.withLock { (baseOffset, totalBytesWritten) }
        precondition(totalBytesWritten <= self.totalBytesWritten)
        precondition(totalBytesWritten >= baseOffset)

        guard totalBytesWritten < self.totalBytesWritten else { return }
        let localLength = totalBytesWritten - baseOffset

        let masterBuffer = localLength == 0
            ? try CMBlockBuffer()
            : try CMBlockBuffer(bufferReference: masterBuffer[0..<localLength])
        lock.withLock { self.masterBuffer = masterBuffer }
        lock.withLock { self.totalBytesWritten = totalBytesWritten }
    }

    func readBuffer(range: Range<Int>) throws -> CMBlockBuffer {
        assert(queue.isCurrent())
        let (baseOffset, totalBytesWritten) = lock.withLock { (baseOffset, totalBytesWritten) }
        precondition(range.lowerBound >= baseOffset)
        precondition(range.upperBound <= totalBytesWritten)

        let localRange = (range.lowerBound - baseOffset)..<(range.upperBound - baseOffset)
        let blockBuffer = try lock.withLock { try CMBlockBuffer(bufferReference: masterBuffer[localRange]) }
        return blockBuffer
    }

    func discardDownstreamTo(absolutePosition: Int?) throws {
        assert(queue.isCurrent())
        let (baseOffset, totalBytesWritten) = lock.withLock { (baseOffset, totalBytesWritten) }
        guard let absolutePosition, absolutePosition > baseOffset else { return }
        precondition(absolutePosition <= totalBytesWritten)

        let localStart = absolutePosition - baseOffset
        let localLength = totalBytesWritten - baseOffset
        let masterBuffer = localStart == localLength
            ? try CMBlockBuffer()
            : try CMBlockBuffer(bufferReference: masterBuffer[localStart..<localLength])
        lock.withLock { self.masterBuffer = masterBuffer }
        lock.withLock { self.baseOffset = absolutePosition }
    }

    func getTotalBytesWritten() -> Int { lock.withLock { totalBytesWritten } }

    func loadSampleData(
        input: DataReader2,
        length: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult {
//        assert(queue.isCurrent())
        do {
            let totalBytesWritten = lock.withLock { totalBytesWritten }
            let buffer = try await input.read(
                range: 0..<length,
                isolation: isolation
            )

            try lock.withLock { try masterBuffer.append(bufferReference: buffer) }
            lock.withLock { self.totalBytesWritten += buffer.dataLength }
            return .success(amount: buffer.dataLength)
        } catch is EndOfFileError {
            if allowEndOfInput {
                return .endOfInput
            } else {
                throw EndOfFileError()
            }
        }
    }

    func loadSampleData(buffer: CMBlockBuffer, lenght: Int, isolation: isolated any Actor) throws {
        assert(queue.isCurrent())
        try lock.withLock {
            try masterBuffer.append(bufferReference: buffer[0..<lenght])
        }
        lock.withLock { totalBytesWritten += lenght }
    }
}
