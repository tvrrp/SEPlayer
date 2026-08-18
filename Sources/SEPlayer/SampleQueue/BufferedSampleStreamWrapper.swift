//
//  BufferedSampleStreamWrapper.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 26.07.2026.
//

import CoreMedia

final class BufferedSampleStreamWrapper: SampleStream {
    var bufferedAheadDuration: CMTime {
        stream.bufferedAheadDuration
    }

    private let stream: any SampleStream
    private let batchMinDuration: CMTime

    private var currentFormat: Format?
    private var nextStreamFormat: Format?
    private var bufferedSamples = [CMSampleBuffer]()

    init(
        stream: any SampleStream,
        batchMinDuration: CMTime = .init(value: 250, timescale: 1000) // 150ms
    ) {
        self.stream = stream
        self.batchMinDuration = batchMinDuration
    }

    func isEqual(to other: any SampleStream) -> Bool {
        stream === other
    }

    func installTrigger(
        condition: SEPlayerCommon.TriggerCondition,
        _ body: ((SEPlayerCommon.QueueTriggerToken) -> Void)?
    ) -> SEPlayerCommon.QueueTriggerToken {
        stream.installTrigger(condition: condition, body)
    }

    func removeTrigger(_ token: SEPlayerCommon.QueueTriggerToken) {
        stream.removeTrigger(token)
    }

    func testTrigger(_ token: SEPlayerCommon.QueueTriggerToken) -> Bool {
        stream.testTrigger(token)
    }

    func isReady() -> Bool {
        stream.isReady() || bufferedAheadDuration >= batchMinDuration
    }

    func maybeThrowError() throws {
        try stream.maybeThrowError()
    }

    func readData(readFlags: ReadFlags) throws -> SampleStreamReadResult {
        if let nextStreamFormat {
            currentFormat = nextStreamFormat
            self.nextStreamFormat = nil
            return .didReadFormat(format: nextStreamFormat)
        }

        while true {
            switch try stream.readData(readFlags: readFlags) {
            case .nothingRead:
                return .nothingRead
            case let .didReadFormat(format):
                if bufferedSamples.isEmpty {
                    currentFormat = format
                    return .didReadFormat(format: format)
                } else {
                    nextStreamFormat = format
                    return try .didReadBuffer(flush())
                }
            case let .didReadBuffer(buffer):
                if buffer.flags.contains(.endOfStream) {
                    return try .didReadBuffer(flush(endOfStreamBuffer: buffer))
                }

                bufferedSamples.append(buffer)
                if bufferedSamples.reduce(CMTime.zero, { $0 + $1.duration }) >= batchMinDuration {
                    return try .didReadBuffer(flush())
                }
            }
        }
    }

    func skipData(position: CMTime) throws -> Int {
        bufferedSamples.removeAll(keepingCapacity: true)
        return try stream.skipData(position: position)
    }

    private func flush(endOfStreamBuffer: CMSampleBuffer? = nil) throws -> CMSampleBuffer {
        if bufferedSamples.isEmpty, let endOfStreamBuffer {
            return endOfStreamBuffer
        }

        let blockBuffer = try CMBlockBuffer(capacity: bufferedSamples.count)
        try bufferedSamples.forEach {
            if let dataBuffer = $0.dataBuffer {
                try blockBuffer.append(bufferReference: dataBuffer)
            }
        }

        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: blockBuffer,
            formatDescription: currentFormat?.buildFormatDescription(),
            numSamples: bufferedSamples.count,
            sampleTimings: bufferedSamples.map {
                CMSampleTimingInfo(
                    duration: $0.duration,
                    presentationTimeStamp: $0.presentationTimeStamp,
                    decodeTimeStamp: $0.decodeTimeStamp
                )
            },
            sampleSizes: bufferedSamples.map { $0.totalSampleSize }
        )

        for (index, buffer) in bufferedSamples.enumerated() {
            if buffer.flags.contains(.lastSample) {
                print()
            }
            sampleBuffer.sampleAttachments[index] = buffer.sampleAttachments[0]
            buffer.propagateAttachments(to: sampleBuffer)
        }

        bufferedSamples.removeAll(keepingCapacity: true)
        return sampleBuffer
    }
}
