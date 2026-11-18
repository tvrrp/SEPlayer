//
//  FakeSampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.11.2025.
//

import CoreMedia
import Foundation
import Testing
@testable import SEPlayer

/// A sample stream over a real `SampleQueue`, fed with predefined samples.
final class FakeSampleStream: SampleStream {
    private(set) var loadingFinished: Bool = false

    var bufferedAheadDuration: CMTime { sampleQueue.bufferedAheadDuration }

    private let queue: Queue
    private let sampleQueue: SampleQueue
    private var sampleStreamItems: [FakeSampleStreamItem]

    private var sampleStreamItemsWritePosition: Int = 0
    private var downstreamFormat: Format?
    private var notifiedDownstreamFormat: Format?

    init(
        queue: Queue,
        initialFormat: Format,
        fakeSampleStreamItems: [FakeSampleStreamItem]
    ) throws {
        self.queue = queue
        self.sampleQueue = try SampleQueue(queue: queue)
        sampleStreamItems = [FakeSampleStreamItem(format: initialFormat)] + fakeSampleStreamItems
    }

    func append(items: [FakeSampleStreamItem]) {
        assert(queue.isCurrent())
        sampleStreamItems.append(contentsOf: items)
    }

    func writeData(startPositionUs: Int64, isolation: isolated any Actor) throws {
        if sampleStreamItemsWritePosition == 0 {
            sampleQueue.setStartTime(.time(us: startPositionUs))
        }
        var writtenFirstFormat = false
        var pendingFirstFormat: Format?

        for (index, fakeSampleStreamItem) in sampleStreamItems.enumerated() {
            guard let sampleInfo = fakeSampleStreamItem.sampleInfo else {
                let format = try #require(fakeSampleStreamItem.format)
                if writtenFirstFormat {
                    sampleQueue.setFormat(format)
                } else {
                    pendingFirstFormat = format
                }
                continue
            }

            if sampleInfo.flags.contains(.endOfStream) {
                loadingFinished = true
                sampleQueue.setLoadingFinished(true)
                break
            }

            if sampleInfo.timeUs >= startPositionUs && index >= sampleStreamItemsWritePosition {
                if !writtenFirstFormat {
                    try sampleQueue.setFormat(#require(pendingFirstFormat))
                    writtenFirstFormat = true
                }

                let time = CMTime.time(us: sampleInfo.timeUs)
                try sampleQueue.sampleData(data: Self.makeBlockBuffer(sampleInfo.data))
                try sampleQueue.sampleMetadata(
                    time: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: time),
                    flags: sampleInfo.flags,
                    range: 0..<sampleInfo.data.count
                )
            }
        }
        sampleStreamItemsWritePosition = sampleStreamItems.count
    }

    func seekTo(positionUs: Int64, allowTimeBeyondBuffer: Bool) -> Bool {
        sampleQueue.seek(time: .time(us: positionUs), allowTimeBeyondBuffer: allowTimeBeyondBuffer)
    }

    func seekWithinBuffer(to position: CMTime) throws -> SampleStreamSeekResult {
        sampleQueue.seekWithinBuffer(to: position)
    }

    func reset() throws {
        try sampleQueue.reset()
        sampleStreamItemsWritePosition = 0
        loadingFinished = false
    }

    func getLargestQueuedTimestamp() -> CMTime {
        sampleQueue.getLargestQueuedTimestamp()
    }

    func isReady() -> Bool {
        sampleQueue.isReady(loadingFinished: loadingFinished)
    }

    func maybeThrowError() throws {
        try sampleQueue.maybeThrowError()
    }

    func discardTo(positionUs: Int64, toKeyframe: Bool) throws {
        try sampleQueue.discard(toTime: .time(us: positionUs), to: toKeyframe, stopAtReadPosition: true)
    }

    func release() {
        try? sampleQueue.release()
    }

    func readData(readFlags: ReadFlags) throws -> SampleStreamReadResult {
        let result = try sampleQueue.read(readFlags: readFlags, loadingFinished: loadingFinished)
        switch result {
        case let .didReadFormat(format):
            downstreamFormat = format
        case .didReadBuffer:
            if !readFlags.contains(.omitSampleData) {
                maybeNotifyDownstreamFormat()
            }
        default:
            break
        }
        return result
    }

    func skipData(position: CMTime) throws -> Int {
        let skipCount = sampleQueue.getSkipCount(time: position, allowEndOfQueue: loadingFinished)
        sampleQueue.skip(count: skipCount)
        return skipCount
    }

    @discardableResult
    func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken {
        sampleQueue.installTrigger(condition: condition, body)
    }

    func removeTrigger(_ token: QueueTriggerToken) {
        sampleQueue.removeTrigger(token)
    }

    func testTrigger(_ token: QueueTriggerToken) -> Bool {
        sampleQueue.testTrigger(token)
    }

    private func maybeNotifyDownstreamFormat() {
        // TODO: event dispatcher
        if let downstreamFormat, downstreamFormat != notifiedDownstreamFormat {
            notifiedDownstreamFormat = downstreamFormat
        }
    }

    private static func makeBlockBuffer(_ bytes: [UInt8]) throws -> CMBlockBuffer {
        let blockBuffer = try CMBlockBuffer(length: bytes.count, flags: .assureMemoryNow)
        try bytes.withUnsafeBytes { try blockBuffer.replaceDataBytes(with: $0) }
        return blockBuffer
    }
}

extension FakeSampleStream {
    struct FakeSampleStreamItem {
        fileprivate var format: Format?
        fileprivate var sampleInfo: SampleInfo?

        static let endOfStream = FakeSampleStreamItem(
            sample: [],
            flags: .endOfStream,
            timeUs: .max
        )

        init(format: Format) {
            self.init(format: format, sampleInfo: nil)
        }

        init(oneByteSample timeUs: Int64, flags: SampleFlags = []) {
            self.init(sampleInfo: .init(data: [0], flags: flags, timeUs: timeUs))
        }

        init(sample data: [UInt8], flags: SampleFlags, timeUs: Int64) {
            self.init(sampleInfo: .init(data: data, flags: flags, timeUs: timeUs))
        }

        private init(format: Format? = nil, sampleInfo: SampleInfo? = nil) {
            precondition((format == nil) != (sampleInfo == nil))
            self.format = format
            self.sampleInfo = sampleInfo
        }
    }

    fileprivate struct SampleInfo {
        fileprivate let data: [UInt8]
        fileprivate let flags: SampleFlags
        fileprivate let timeUs: Int64
    }
}

/// Format descriptions for the tests' formats, which carry no codec configuration: a sample
/// queue builds one for every sample it hands out.
struct FakeInitializationData: Format.InitializationData {
    func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
        switch format.sampleMimeType?.trackType {
        case .audio:
            let description = AudioStreamBasicDescription(
                mSampleRate: Float64(max(format.sampleRate, 1)),
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 1024,
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(max(format.channelCount, 1)),
                mBitsPerChannel: 0,
                mReserved: 0
            )
            return try CMAudioFormatDescription(audioStreamBasicDescription: description)
        default:
            return try CMVideoFormatDescription(
                videoCodecType: .h264,
                width: max(format.width, 1),
                height: max(format.height, 1)
            )
        }
    }
}
