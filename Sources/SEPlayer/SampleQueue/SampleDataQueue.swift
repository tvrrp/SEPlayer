//
//  SampleDataQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.07.2026.
//

import CoreMedia
import SEPlayerCommon

final class SampleDataQueue {
    private let queue: Queue

    // TODO: RWLock
    private var masterBuffer: CMBlockBuffer
    // TODO: Atomics
    private var baseOffset: Int
    private var totalBytesWritten: Int

    init(queue: Queue) throws {
        self.queue = queue
        masterBuffer = try CMBlockBuffer()
        baseOffset = 0
        totalBytesWritten = 0
    }

    func reset() throws {
        assert(queue.isCurrent())
        masterBuffer = try CMBlockBuffer()
        baseOffset = 0
        totalBytesWritten = 0
    }

    func discardUpstreamSampleBytes(totalBytesWritten: Int) throws {
        assert(queue.isCurrent())
        precondition(totalBytesWritten <= self.totalBytesWritten)
        precondition(totalBytesWritten >= baseOffset)

        guard totalBytesWritten < self.totalBytesWritten else { return }
        let localLength = totalBytesWritten - baseOffset

        masterBuffer = localLength == 0
            ? try CMBlockBuffer()
            : try CMBlockBuffer(bufferReference: masterBuffer[0..<localLength])
        self.totalBytesWritten = totalBytesWritten
    }

    func readBuffer(range: Range<Int>) throws -> CMBlockBuffer {
        assert(queue.isCurrent())
        precondition(range.lowerBound >= baseOffset)
        precondition(range.upperBound <= totalBytesWritten)

        let localRange = (range.lowerBound - baseOffset)..<(range.upperBound - baseOffset)
        return try CMBlockBuffer(bufferReference: masterBuffer[localRange])
    }

    func discardDownstreamTo(absolutePosition: Int?) throws {
        assert(queue.isCurrent())
        guard let absolutePosition, absolutePosition > baseOffset else { return }
        precondition(absolutePosition <= totalBytesWritten)

        let localStart = absolutePosition - baseOffset
        let localLength = totalBytesWritten - baseOffset
        masterBuffer = localStart == localLength
            ? try CMBlockBuffer()
            : try CMBlockBuffer(bufferReference: masterBuffer[localStart..<localLength])
        baseOffset = absolutePosition
    }

    func getTotalBytesWritten() -> Int { totalBytesWritten }

    func loadSampleData(buffer: CMBlockBuffer, isolation: isolated any Actor) throws {
        assert(queue.isCurrent())
        try masterBuffer.append(bufferReference: buffer)
        totalBytesWritten += buffer.dataLength
    }
}
