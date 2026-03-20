//
//  SampleQueue2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.04.2025.
//

import CoreMedia
import Decoder
import Foundation
import Extractor
import SEPlayerCommon

protocol SampleQueueDelegate: AnyObject {
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: Format)
}

class SampleQueue: TrackOutput {
    weak var delegate: SampleQueueDelegate?

    private let queue: Queue
    private let sampleDataQueue: SampleDataQueue
    private let lock: NSRecursiveLock

    private var downstreamFormat: Format?

    private var capacity: Int
    private var samples: ContiguousArray<SampleWrapper>

    private var length: Int = 0
    private var absoluteFirstIndex: Int = 0
    private var relativeFirstIndex: Int = 0
    private var readPosition: Int = 0

    private var startTime: CMTime
    private var largestDiscardedTimestamp: CMTime
    private var largestQueuedTimestamp: CMTime

    private var isLastSampleQueued: Bool = false
    private var upstreamKeyframeRequired: Bool
    private var upstreamFormatRequired: Bool

    private var upstreamFormatAdjustmentRequired = false
    private var unadjustedUpstreamFormat: Format?
    private var upstreamFormat: Format?

    private var allSamplesAreSyncSamples: Bool
    private var sampleOffset: CMTime = .zero

    private var pendingSplice: Bool = false

    private var sharedSampleMetadata: SpannedData<Format>

    private var _backBufferDuration: CMTime? = nil

    init(queue: Queue, allocator: Allocator) {
        self.queue = queue
        sampleDataQueue = SampleDataQueue(queue: queue, allocator: allocator)
        lock = NSRecursiveLock()
        capacity = SampleQueue.sampleCapacityIncrement
        samples = ContiguousArray(repeating: .init(), count: capacity)
        sharedSampleMetadata = SpannedData<Format>(removeCallback: { _ in }) // TODO: fix
        startTime = .negativeInfinity
        largestDiscardedTimestamp = .negativeInfinity
        largestQueuedTimestamp = .negativeInfinity
        upstreamFormatRequired = true
        upstreamKeyframeRequired = true
        allSamplesAreSyncSamples = true
    }

    func release() { reset(resetUpstreamFormat: true) }
    final func reset() { reset(resetUpstreamFormat: false) }

    func reset(resetUpstreamFormat: Bool) {
        sampleDataQueue.reset()
        length = 0
        absoluteFirstIndex = 0
        relativeFirstIndex = 0
        readPosition = 0
        upstreamKeyframeRequired = true
        startTime = .negativeInfinity
        largestDiscardedTimestamp = .negativeInfinity
        largestQueuedTimestamp = .negativeInfinity
        isLastSampleQueued = false
        sharedSampleMetadata.clear()
        if resetUpstreamFormat {
            upstreamFormat = nil
            upstreamFormatRequired = true
            allSamplesAreSyncSamples = true
        }
    }

    final func setStartTime(_ startTime: CMTime) {
        self.startTime = startTime
    }

    final func splice() {
        pendingSplice = true
    }

    final func getWriteIndex() -> Int {
        return absoluteFirstIndex + length
    }

    final func discardUpstreamSamples(discardFromIndex: Int) {
        sampleDataQueue.discardUpstreamSampleBytes(
            totalBytesWritten: discardUpstreamSampleMetadata(
                discardFromIndex: discardFromIndex
            )
        )
    }

    final func discardUpstreamFrom(time: CMTime) {
        guard length > 0 else { return }

        let retainCount = countUnreadSamplesBefore(time: time)
        discardUpstreamSamples(discardFromIndex: absoluteFirstIndex + retainCount)
    }

    func preRelease() {
        discardToEnd()
    }

    func maybeThrowError() throws {}

    final func getFirstIndex() -> Int {
        return absoluteFirstIndex
    }

    final func getReadIndex() -> Int {
        return absoluteFirstIndex + readPosition
    }

    final func getUpstreamFormat() -> Format? {
        lock.withLock { return upstreamFormatRequired ? nil : upstreamFormat }
    }

    final func getLargestQueuedTimestamp() -> CMTime {
        lock.withLock { return largestQueuedTimestamp }
    }

    final func getLargestReadTimestamp() -> CMTime {
        lock.withLock { return max(largestDiscardedTimestamp, getLargestTimestamp(length: readPosition)) }
    }

    final func lastSampleQueued() -> Bool { lock.withLock { isLastSampleQueued } }

    final func getFirstTimestamp() -> CMTime {
        lock.withLock { return length == 0 ? .negativeInfinity : samples[relativeFirstIndex].time.decodeTimeStamp }
    }

    func isReady(loadingFinished: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !hasNextSample() {
            return loadingFinished
                || isLastSampleQueued
                || (upstreamFormat != nil && upstreamFormat != downstreamFormat)
        }

        if sharedSampleMetadata.get(getReadIndex()) != downstreamFormat {
            return true
        }

        return true
    }

    func read(buffer: DecoderInputBuffer, readFlags: ReadFlags, loadingFinished: Bool) throws -> SampleStreamReadResult {
        let (result, extras) = peekSampleMetadata(
            buffer: buffer,
            formatRequired: readFlags.contains(.requireFormat),
            loadingFinished: loadingFinished
        )

        if result == .didReadBuffer, let extras, !buffer.flags.contains(.endOfStream) {
            let peek = readFlags.contains(.peek)
            if !readFlags.contains(.omitSampleData) {
                // TODO: move to sampleDataQueue
                try buffer.ensureSpaceForWrite(extras.size)
                let target = try buffer.dequeue()
                if peek {
                    try! sampleDataQueue.peekToBuffer(
                        target: target,
                        offset: extras.offset,
                        size: extras.size
                    )
                } else {
                    try! sampleDataQueue.readToBuffer(
                        target: target,
                        offset: extras.offset,
                        size: extras.size
                    )
                }

                buffer.commitWrite(amount: extras.size)
            }

            if !peek { readPosition += 1 }

            if !peek,
               let backBuffer = backBufferDuration,
               !buffer.flags.contains(.endOfStream),
               buffer.time.presentationTimeStamp > .negativeInfinity {
                let discardThreshold = buffer.time.presentationTimeStamp - backBuffer
                // `to: true` keeps samples up to the keyframe that anchors the back buffer,
                // ensuring seeks into the retained window always have a valid decode point.
                discard(toTime: discardThreshold, to: true, stopAtReadPosition: false)
            }
        }

        return result
    }

    @discardableResult
    func seek(to sampleIndex: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rewind()
        if sampleIndex < absoluteFirstIndex || sampleIndex > absoluteFirstIndex + length {
            return false
        }
        startTime = .negativeInfinity
        readPosition = sampleIndex - absoluteFirstIndex
        return true
    }

    @discardableResult
    func seek(time: CMTime, allowTimeBeyondBuffer: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rewind()
        let relativeReadIndex = getRelativeIndex(offset: readPosition)

        if !hasNextSample() || time < samples[relativeReadIndex].time.presentationTimeStamp
            || time > largestQueuedTimestamp && !allowTimeBeyondBuffer {
            return false
        }

        let offset = if allSamplesAreSyncSamples {
            findSampleAfter(
                relativeStartIndex: relativeReadIndex,
                length: length - readPosition,
                time: time,
                allowTimeBeyondBuffer: allowTimeBeyondBuffer
            )
        } else {
            findSampleBefore(
                relativeStartIndex: relativeReadIndex,
                length: length - readPosition,
                time: time,
                keyframe: true
            )
        }

        guard offset != -1 else {
            return false
        }
        startTime = time
        readPosition += offset
        return true
    }

    final func getSkipCount(time: CMTime, allowEndOfQueue: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        let relativeReadIndex = getRelativeIndex(offset: readPosition)
        if !hasNextSample() || time < samples[relativeReadIndex].time.presentationTimeStamp {
            return .zero
        }
        if time > largestQueuedTimestamp && allowEndOfQueue {
            return length - readPosition
        }

        let offset = findSampleBefore(
            relativeStartIndex: relativeReadIndex,
            length: length - readPosition,
            time: time,
            keyframe: true
        )

        return offset == -1 ? 0 : offset
    }

    final func skip(count: Int) {
        lock.lock(); defer { lock.unlock() }
        assert(count >= 0 && readPosition + count <= length)
        readPosition += count
    }

    final func discard(toTime: CMTime, to keyframe: Bool, stopAtReadPosition: Bool) {
        sampleDataQueue.discardDownstreamTo(
            absolutePosition: discardSampleMetadata(
                toTime: toTime, to: keyframe, stopAtReadPosition: stopAtReadPosition
            )
        )
    }

    final func discardToRead() {
        sampleDataQueue.discardDownstreamTo(
            absolutePosition: discardSampleMetadataToRead()
        )
    }

    final func discardToEnd() {
        sampleDataQueue.discardDownstreamTo(
            absolutePosition: discardSampleMetadataToEnd()
        )
    }

    func setSampleOffsetTime(_ sampleOffsetTime: CMTime) {
        guard sampleOffsetTime != self.sampleOffset else { return }
        self.sampleOffset = sampleOffsetTime
        invalidateUpstreamFormatAdjustment()
    }

    func discardSampleMetadataToRead() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard readPosition != 0 else { return nil }
        return discardSamples(discardCount: readPosition)
    }

    func discardSampleMetadataToEnd() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard length != 0 else { return nil }
        return discardSamples(discardCount: length)
    }

    func getAdjustedUpstreamFormat(_ format: Format) -> Format {
        var format = format
        if sampleOffset != .zero, format.subsampleOffset != Format.offsetSampleRelative {
            format = format.buildUpon()
                .setSubsampleOffset(sampleOffset)
                .build()
        }
        return format
    }

    final func loadSampleData(
        input: DataReader,
        length: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult {
        try await sampleDataQueue.loadSampleData(
            input: input,
            length: length,
            allowEndOfInput: allowEndOfInput,
            isolation: isolation
        )
    }

    func sampleData(data: ByteBuffer, length: Int, isolation: isolated any Actor) throws {
        try sampleDataQueue.loadSampleData(buffer: data, length: length, isolation: isolation)
    }

    func setFormat(_ format: Format, isolation: isolated any Actor) {
        let adjustedUpstreamFormat = getAdjustedUpstreamFormat(format)
        upstreamFormatAdjustmentRequired = false
        unadjustedUpstreamFormat = format
        if setUpstreamFormat(adjustedUpstreamFormat) {
            queue.async { self.delegate?.sampleQueue(self, didChange: adjustedUpstreamFormat) }
        }
    }

    final func invalidateUpstreamFormatAdjustment() {
        upstreamFormatAdjustmentRequired = true
    }

    func sampleMetadata(time: CMSampleTimingInfo, flags: SampleFlags, size: Int, offset: Int, isolation: isolated any Actor) {
        if upstreamFormatAdjustmentRequired, let unadjustedUpstreamFormat {
            setFormat(unadjustedUpstreamFormat, isolation: isolation)
        }

        let isKeyframe = flags.contains(.keyframe)
        var flags = flags
        if upstreamKeyframeRequired {
            guard isKeyframe else { return }
            upstreamKeyframeRequired = false
        }

        let time = CMSampleTimingInfo(
            duration: time.duration,
            presentationTimeStamp: time.presentationTimeStamp + sampleOffset,
            decodeTimeStamp: time.decodeTimeStamp
        )
        if allSamplesAreSyncSamples {
            if time.presentationTimeStamp < startTime { return }
            // TODO: log bad data
            flags.insert(.keyframe)
        }

        if pendingSplice {
            if !isKeyframe || !attemptSplice(time: time.presentationTimeStamp) {
                return
            }
            pendingSplice = false
        }

        let absoluteOffset = sampleDataQueue.getTotalBytesWritten() - size - offset
        commitSample(time: time, sampleFlags: flags, offset: absoluteOffset, size: size)
    }
}

extension SampleQueue {
    var bufferedAheadDuration: CMTime {
        lock.withLock {
            guard readPosition < length else { return .zero }
            let readIndex = getRelativeIndex(offset: readPosition)
            return max(.zero, largestQueuedTimestamp - samples[readIndex].time.presentationTimeStamp)
        }
    }

    var readableSampleCount: Int {
        lock.withLock { length - readPosition }
    }

    var minReadableTimestamp: CMTime? {
        lock.withLock {
            guard readPosition < length else { return nil }
            return samples[getRelativeIndex(offset: readPosition)].time.presentationTimeStamp
        }
    }

    var hasReadableSamples: Bool { readableSampleCount > 0 }

    var isEndOfData: Bool { lastSampleQueued() && !hasReadableSamples }

    var backBufferDuration: CMTime? {
        get { lock.withLock { _backBufferDuration } }
        set { lock.withLock { _backBufferDuration = newValue } }
    }
}

private extension SampleQueue {
    private func discardSampleMetadata(toTime: CMTime, to keyframe: Bool, stopAtReadPosition: Bool) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if length == 0 || toTime < samples[relativeFirstIndex].time.presentationTimeStamp { return nil }

        let searchLength = stopAtReadPosition && readPosition != length ? readPosition + 1 : length
        let discardCount = findSampleBefore(
            relativeStartIndex: relativeFirstIndex,
            length: searchLength,
            time: toTime,
            keyframe: keyframe
        )

        return discardCount == -1 ? nil : discardSamples(discardCount: discardCount)
    }

    private func rewind() {
        lock.lock(); defer { lock.unlock() }
        readPosition = 0
        sampleDataQueue.rewind()
    }

    private func peekSampleMetadata(
        buffer: DecoderInputBuffer,
        formatRequired: Bool,
        loadingFinished: Bool
    ) -> (result: SampleStreamReadResult, extras: SampleExtrasHolder?) {
        lock.lock(); defer { lock.unlock() }
        if !hasNextSample() {
            if loadingFinished || isLastSampleQueued {
                buffer.flags = .endOfStream
                buffer.time = .init(
                    duration: .invalid,
                    presentationTimeStamp: .positiveInfinity,
                    decodeTimeStamp: .positiveInfinity
                )
                return (.didReadBuffer, nil)
            } else if let upstreamFormat, (formatRequired || upstreamFormat != downstreamFormat) {
                downstreamFormat = upstreamFormat
                return (.didReadFormat(format: upstreamFormat), nil)
            } else {
                return (.nothingRead, nil)
            }
        }

        let format = sharedSampleMetadata.get(getReadIndex())
        if formatRequired || format != downstreamFormat {
            downstreamFormat = format
            return (.didReadFormat(format: format),nil)
        }

        let relativeReadIndex = getRelativeIndex(offset: readPosition)
        let sampleInfo = samples[relativeReadIndex]
        buffer.flags = sampleInfo.flags
        if readPosition == (length - 1) && (loadingFinished || isLastSampleQueued) {
            buffer.flags.insert(.lastSample)
        }

        buffer.size = sampleInfo.size
        buffer.time = sampleInfo.time
        let extras = SampleExtrasHolder(
            size: sampleInfo.size,
            offset: sampleInfo.offset
        )

        return (.didReadBuffer, extras)
    }

    private func setUpstreamFormat(_ format: Format) -> Bool {
        lock.lock(); defer { lock.unlock() }
        upstreamFormatRequired = false
        guard format !== upstreamFormat else { return false }

        if !sharedSampleMetadata.isEmpty, sharedSampleMetadata.getEndValue() == format {
            upstreamFormat = sharedSampleMetadata.getEndValue()
        } else {
            upstreamFormat = format
        }

        if let upstreamFormat {
            let mimeType = upstreamFormat.sampleMimeType
            allSamplesAreSyncSamples = mimeType.allSamplesAreSyncSamples(codec: upstreamFormat.codecs)
        }

        return true
    }

    private func commitSample(time: CMSampleTimingInfo, sampleFlags: SampleFlags, offset: Int, size: Int) {
        lock.lock(); defer { lock.unlock() }
        if length > 0 {
            let previousSampleRelativeIndex = getRelativeIndex(offset: length - 1)
            assert(samples[previousSampleRelativeIndex].offset + samples[previousSampleRelativeIndex].size <= offset)
        }

        isLastSampleQueued = sampleFlags.contains(.lastSample)
        largestQueuedTimestamp = max(largestQueuedTimestamp, time.presentationTimeStamp)

        let relativeEndIndex = getRelativeIndex(offset: length)
        samples[relativeEndIndex] = .init(offset: offset, size: size, flags: sampleFlags, time: time)

        if sharedSampleMetadata.isEmpty || sharedSampleMetadata.getEndValue() != upstreamFormat,
           let upstreamFormat {
            sharedSampleMetadata.appendSpan(startKey: getWriteIndex(), value: upstreamFormat)
        }

        length += 1

        if length == capacity {
            let newCapacity = capacity + SampleQueue.sampleCapacityIncrement
            var newArray = ContiguousArray<SampleWrapper>(repeating: .init(), count: newCapacity)

            let beforeWrap = capacity - relativeFirstIndex
            let afterWrap = relativeFirstIndex
            newArray.replaceSubrange(0..<beforeWrap, with: samples[relativeFirstIndex..<capacity])
            newArray.replaceSubrange(beforeWrap..<(beforeWrap + afterWrap), with: samples[0..<afterWrap])

            samples = newArray
            relativeFirstIndex = 0
            capacity = newCapacity
        }
    }

    private func attemptSplice(time: CMTime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard length != 0 else { return time > largestDiscardedTimestamp }
        guard getLargestReadTimestamp() < time else { return false }

        let retainCount = countUnreadSamplesBefore(time: time)
        discardUpstreamSampleMetadata(discardFromIndex: absoluteFirstIndex + retainCount)
        return true
    }

    @discardableResult
    private func discardUpstreamSampleMetadata(discardFromIndex: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let discardCount = getWriteIndex() - discardFromIndex
        length -= discardCount
        largestQueuedTimestamp = max(largestDiscardedTimestamp, getLargestTimestamp(length: length))
        isLastSampleQueued = discardCount == 0 && isLastSampleQueued
        sharedSampleMetadata.discard(from: discardFromIndex)
        if length != 0 {
            let relativeLastWriteIndex = getRelativeIndex(offset: length - 1)
            return samples[relativeLastWriteIndex].offset + samples[relativeLastWriteIndex].size
        }
        return 0
    }

    private func hasNextSample() -> Bool {
        return readPosition != length
    }

    private func findSampleBefore(relativeStartIndex: Int, length: Int, time: CMTime, keyframe: Bool) -> Int {
        var sampleCountToTarget = -1
        var searchIndex = relativeStartIndex

        for i in 0..<length where samples[searchIndex].time.presentationTimeStamp <= time {
            if !keyframe || samples[searchIndex].flags.contains(.keyframe) {
                sampleCountToTarget = i

                if samples[searchIndex].time.presentationTimeStamp == time {
                    break
                }
            }

            searchIndex += 1
            if searchIndex == capacity {
                searchIndex = 0
            }
        }

        return sampleCountToTarget
    }

    private func findSampleAfter(relativeStartIndex: Int, length: Int, time: CMTime, allowTimeBeyondBuffer: Bool) -> Int {
        var searchIndex = relativeStartIndex
        for i in 0..<length {
            if samples[searchIndex].time.presentationTimeStamp >= time {
                return i
            }
            searchIndex += 1
            if searchIndex == capacity {
                searchIndex = 0
            }
        }
        return allowTimeBeyondBuffer ? length : -1
    }

    private func countUnreadSamplesBefore(time: CMTime) -> Int {
        var count = length
        var relativeSampleIndex = getRelativeIndex(offset: length - 1)

        while count > readPosition, samples[relativeSampleIndex].time.presentationTimeStamp >= time {
            count -= 1
            relativeSampleIndex -= 1
            if relativeSampleIndex == -1 {
                relativeSampleIndex = capacity - 1
            }
        }

        return count
    }

    private func discardSamples(discardCount: Int) -> Int {
        largestDiscardedTimestamp = max(largestDiscardedTimestamp, getLargestTimestamp(length: discardCount))
        length -= discardCount
        absoluteFirstIndex += discardCount
        relativeFirstIndex += discardCount
        if relativeFirstIndex >= capacity {
            relativeFirstIndex -= capacity
        }
        readPosition -= discardCount
        readPosition = max(0, readPosition)
        sharedSampleMetadata.discard(to: absoluteFirstIndex)

        if length == 0 {
            let relativeLastDiscardIndex = (relativeFirstIndex == 0 ? capacity : relativeFirstIndex) - 1
            return samples[relativeLastDiscardIndex].offset + samples[relativeLastDiscardIndex].size
        } else {
            return samples[relativeFirstIndex].offset
        }
    }

    private func getLargestTimestamp(length: Int) -> CMTime {
        guard length > 0 else { return .negativeInfinity }

        var largestTimestamp = CMTime.negativeInfinity
        var relativeSampleIndex = getRelativeIndex(offset: length - 1)

        for _ in 0..<length {
            largestTimestamp = max(largestTimestamp, samples[relativeSampleIndex].time.presentationTimeStamp)
            if samples[relativeSampleIndex].flags.contains(.keyframe) {
                break
            }
            relativeSampleIndex -= 1
            if relativeSampleIndex == -1 {
                relativeSampleIndex = capacity - 1
            }
        }

        return largestTimestamp
    }

    private func getRelativeIndex(offset: Int) -> Int {
        let relativeIndex = relativeFirstIndex + offset
        return relativeIndex < capacity ? relativeIndex : relativeIndex - capacity
    }
}

extension SampleQueue {
    static let sampleCapacityIncrement: Int = 1000

    struct SampleExtrasHolder {
        let size: Int
        let offset: Int
    }

    private struct SampleWrapper {
        let offset: Int
        let size: Int
        let flags: SampleFlags
        let time: CMSampleTimingInfo

        init(
            offset: Int = 0,
            size: Int = 0,
            flags: SampleFlags = .init(),
            time: CMSampleTimingInfo = .invalid
        ) {
            self.offset = offset
            self.size = size
            self.flags = flags
            self.time = time
        }
    }
}

extension SampleQueue: CustomDebugStringConvertible {
    var debugDescription: String {
        "\(upstreamFormat!)"
    }
}
