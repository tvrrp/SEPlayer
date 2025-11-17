//
//  FakeSampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.11.2025.
//

import Foundation
import Testing
@testable import SEPlayer

final class FakeSampleStream: SampleStream {
    var loadingFinished: Bool = false

    private let queue: Queue
    private let sampleQueue: SampleQueue
    private var sampleStreamItems: [FakeSampleStreamItem]

    private var sampleStreamItemsWritePosition: Int = 0
    private var downstreamFormat: Format?
    private var notifiedDownstreamFormat: Format?

    init(
        queue: Queue,
        allocator: Allocator,
        initialFormat: Format,
        fakeSampleStreamItems: [FakeSampleStreamItem]
    ) {
        self.queue = queue
        self.sampleQueue = SampleQueue(queue: queue, allocator: allocator)
        sampleStreamItems = [FakeSampleStreamItem(format: initialFormat)] + fakeSampleStreamItems
    }

    func append(items: [FakeSampleStreamItem]) {
        assert(queue.isCurrent())
        sampleStreamItems.append(contentsOf: items)
    }

    func writeData(startPositionUs: Int64) throws {
        if sampleStreamItemsWritePosition == 0 {
            sampleQueue.setStartTime(startPositionUs)
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
                break
            }

            if sampleInfo.timeUs >= startPositionUs && index >= sampleStreamItemsWritePosition {
                if !writtenFirstFormat {
                    try sampleQueue.setFormat(#require(pendingFirstFormat))
                    writtenFirstFormat = true
                }

                try sampleQueue.sampleData(
                    data: sampleInfo.data,
                    length: sampleInfo.data.readableBytes
                )
                sampleQueue.sampleMetadata(
                    time: sampleInfo.timeUs,
                    flags: sampleInfo.flags,
                    size: sampleInfo.data.readableBytes,
                    offset: 0
                )
            }
        }
        sampleStreamItemsWritePosition = sampleStreamItems.count
    }

    func seekTo(positionUs: Int64, allowTimeBeyondBuffer: Bool) -> Bool {
        sampleQueue.seek(to: positionUs, allowTimeBeyondBuffer: allowTimeBeyondBuffer)
    }

    func reset() {
        sampleQueue.reset()
        sampleStreamItemsWritePosition = 0
        loadingFinished = false
    }

    func getLargestQueuedTimestampUs() -> Int64 {
        sampleQueue.getLargestQueuedTimestamp()
    }

    func isReady() -> Bool {
        sampleQueue.isReady(loadingFinished: loadingFinished)
    }

    func discardTo(positionUs: Int64, toKeyframe: Bool) {
        sampleQueue.discard(to: positionUs, to: toKeyframe, stopAtReadPosition: true)
    }

    func release() { sampleQueue.release() }

    func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult {
        let result = try sampleQueue.read(buffer: buffer, readFlags: readFlags, loadingFinished: loadingFinished)
        switch result {
        case let .didReadFormat(format):
            downstreamFormat = format
        case .didReadBuffer:
            if !readFlags.contains(.omitSampleData) {
                maybeNotifyDownstreamFormat(timeUs: buffer.time)
            }
        default:
            break
        }
        return result
    }

    func skipData(position: Int64) -> Int {
        let skipCount = sampleQueue.getSkipCount(time: position, allowEndOfQueue: loadingFinished)
        sampleQueue.skip(count: skipCount)
        return skipCount
    }

    private func maybeNotifyDownstreamFormat(timeUs: Int64) {
        // TODO: event dispatcher
        if let downstreamFormat, downstreamFormat != notifiedDownstreamFormat {
            // TODO: notify event dispatcher
            notifiedDownstreamFormat = downstreamFormat
        }
    }
}

extension FakeSampleStream {
    struct FakeSampleStreamItem {
        fileprivate var format: Format?
        fileprivate var sampleInfo: SampleInfo?

        static let endOfStream = FakeSampleStreamItem(
            sample: ByteBuffer(),
            flags: .endOfStream,
            timeUs: .max
        )

        init(format: Format) {
            self.init(format: format, sampleInfo: nil)
        }

        init(oneByteSample timeUs: Int64, flags: SampleFlags = []) {
            self.init(sampleInfo: .init(
                data: ByteBuffer(repeating: 0, count: 1),
                flags: flags,
                timeUs: timeUs
            ))
        }

        init(sample data: ByteBuffer, flags: SampleFlags, timeUs: Int64) {
            self.init(sampleInfo: .init(data: data, flags: flags, timeUs: timeUs))
        }

        private init(format: Format? = nil, sampleInfo: SampleInfo? = nil) {
            try! #require((format == nil) != (sampleInfo == nil))
            self.format = format
            self.sampleInfo = sampleInfo
        }
    }

    fileprivate struct SampleInfo {
        fileprivate let data: ByteBuffer
        fileprivate let flags: SampleFlags
        fileprivate let timeUs: Int64

        init(data: ByteBuffer, flags: SampleFlags, timeUs: Int64) {
            self.data = data
            self.flags = flags
            self.timeUs = timeUs
        }
    }
}
