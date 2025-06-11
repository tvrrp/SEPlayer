//
//  SampleQueue2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.04.2025.
//

import CoreMedia.CMFormatDescription

protocol SampleQueueDelegate: AnyObject {
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: CMFormatDescription)
}

class SampleQueue {
    weak var delegate: SampleQueueDelegate?

    private let queue: Queue
    private let sampleDataQueue: SampleDataQueue
    private let lock: NSRecursiveLock

    private var downstreamFormat: CMFormatDescription?

    private var capacity: Int
    private var samples: [SampleWrapper]

    private var length: Int = 0
    private var absoluteFirstIndex: Int = 0
    private var relativeFirstIndex: Int = 0
    private var readPosition: Int = 0

    private var startTime: Int64
    private var largestDiscardedTimestamp: Int64
    private var largestQueuedTimestamp: Int64

    private var isLastSampleQueued: Bool = false
    private var upstreamKeyframeRequired: Bool
    private var upstreamFormatRequired: Bool

    private var upstreamFormat: CMFormatDescription?

    private var allSamplesAreSyncSamples: Bool
    private var sampleOffsetTime: Int64 = 0

    private var pendingSplice: Bool = false

    private var sharedSampleMetadata: [(Int, CMFormatDescription)] = []

    init(queue: Queue, allocator: Allocator) {
        self.queue = queue
        sampleDataQueue = SampleDataQueue(queue: queue, allocator: allocator)
        lock = NSRecursiveLock()
        capacity = 1000
        samples = Array(repeating: .init(), count: capacity)
        startTime = .min
        largestDiscardedTimestamp = .min
        largestQueuedTimestamp = .min
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
        startTime = .min
        largestDiscardedTimestamp = .min
        largestQueuedTimestamp = .min
        isLastSampleQueued = false
        sharedSampleMetadata.removeAll()
        if resetUpstreamFormat {
            upstreamFormat = nil
            upstreamFormatRequired = true
            allSamplesAreSyncSamples = true
        }
    }

    final func setStartTime(_ startTime: Int64) {
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

    final func discardUpstreamFrom(time: Int64) {
        guard length > 0 else { return }

        let retainCount = countUnreadSamplesBefore(time: time)
        discardUpstreamSamples(discardFromIndex: absoluteFirstIndex + retainCount)
    }

    func preRelease() {
        discardToEnd()
    }

    final func getFirstIndex() -> Int {
        return absoluteFirstIndex
    }

    final func getReadIndex() -> Int {
        return absoluteFirstIndex + readPosition
    }

    final func getUpstreamFormat() -> CMFormatDescription? {
        lock.withLock { return upstreamFormatRequired ? nil : upstreamFormat }
    }

    final func getLargestQueuedTimestamp() -> Int64 {
        lock.withLock { return largestQueuedTimestamp }
    }

    final func getLargestReadTimestamp() -> Int64 {
        lock.withLock { return max(largestDiscardedTimestamp, getLargestTimestamp(length: readPosition)) }
    }

    final func lastSampleQueued() -> Bool { lock.withLock { isLastSampleQueued } }

    final func getFirstTimestamp() -> Int64 {
        lock.withLock { return length == 0 ? .min : samples[relativeFirstIndex].time }
    }

    func isReady(loadingFinished: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !hasNextSample() {
            return loadingFinished
                || isLastSampleQueued
                || (upstreamFormat != nil && upstreamFormat != downstreamFormat)
        }

        if let currentFormat = sharedSampleMetadata.first(where: { $0.0 == getReadIndex() })?.1,
           let downstreamFormat, currentFormat != downstreamFormat {
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
                let data = try! buffer.dequeue()
                if peek {
                    try! sampleDataQueue.peekToBuffer(
                        buffer: data,
                        offset: extras.offset,
                        size: extras.size
                    )
                } else {
                    try! sampleDataQueue.readToBuffer(
                        buffer: data,
                        offset: extras.offset,
                        size: extras.size
                    )
                }
                buffer.size = extras.size
            }

            if !peek { readPosition += 1 }
        }

        return result
    }

    final func seek(to sampleIndex: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rewind()
        if sampleIndex < absoluteFirstIndex || sampleIndex > absoluteFirstIndex + length {
            return false
        }
        startTime = .min
        readPosition = sampleIndex - absoluteFirstIndex
        return true
    }

    final func seek(to time: Int64, allowTimeBeyondBuffer: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rewind()
        let relativeReadIndex = getRelativeIndex(offset: readPosition)

        if !hasNextSample() || time < samples[relativeReadIndex].time
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

        guard offset != -1 else { return false }
        startTime = time
        readPosition += offset
        return true
    }

    final func getSkipCount(time: Int64, allowEndOfQueue: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        let relativeReadIndex = getRelativeIndex(offset: readPosition)
        if !hasNextSample() || time < samples[relativeReadIndex].time {
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

    final func discard(to time: Int64, to keyframe: Bool, stopAtReadPosition: Bool) {
        sampleDataQueue.discardDownstreamTo(
            absolutePosition: discardSampleMetadata(
                to: time, to: keyframe, stopAtReadPosition: stopAtReadPosition
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

    func setSampleOffsetTime(_ sampleOffsetTime: Int64) {
        guard sampleOffsetTime != self.sampleOffsetTime else { return }
        self.sampleOffsetTime = sampleOffsetTime
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
}

extension SampleQueue: TrackOutput {
    final func loadSampleData(input: DataReader, length: Int, allowEndOfInput: Bool) throws -> DataReaderReadResult {
        try sampleDataQueue.loadSampleData(input: input, length: length, allowEndOfInput: allowEndOfInput)
    }

    func setFormat(_ format: CMFormatDescription) {
        if setUpstreamFormat(format) {
            queue.async { self.delegate?.sampleQueue(self, didChange: format) }
        }
    }

    func sampleMetadata(time: Int64, flags: SampleFlags, size: Int, offset: Int) {
        let isKeyframe = flags.contains(.keyframe)
        if upstreamKeyframeRequired {
            guard isKeyframe else { return }
            upstreamKeyframeRequired = false
        }

        let time = time + sampleOffsetTime
        if allSamplesAreSyncSamples {
            if time < startTime { return }
            // TODO: update samples flags
        }

        if pendingSplice {
            if !isKeyframe || !attemptSplice(time: time) {
                return
            }
            pendingSplice = false
        }

        let absoluteOffset = sampleDataQueue.getTotalBytesWritten() - size - offset
        commitSample(time: time, sampleFlags: flags, offset: absoluteOffset, size: size)
    }
}

private extension SampleQueue {
    private func discardSampleMetadata(to time: Int64, to keyframe: Bool, stopAtReadPosition: Bool) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if length == 0 || time < samples[relativeFirstIndex].time { return nil }

        let searchLength = stopAtReadPosition && readPosition != length ? readPosition + 1 : length
        let discardCount = findSampleBefore(
            relativeStartIndex: relativeFirstIndex,
            length: searchLength,
            time: time,
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
                buffer.time = .endOfSource
                return (.didReadBuffer, nil)
            } else if let upstreamFormat, (formatRequired || upstreamFormat != downstreamFormat) {
                downstreamFormat = upstreamFormat
                return (.didReadFormat(format: upstreamFormat), nil)
            } else {
                return (.nothingRead, nil)
            }
        }

        let readIndex = getReadIndex()
        if let format = sharedSampleMetadata.first(where: { $0.0 == readIndex })?.1,
           formatRequired || format != downstreamFormat {
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

    private func setUpstreamFormat(_ format: CMFormatDescription) -> Bool {
        lock.lock(); defer { lock.unlock() }
        upstreamFormatRequired = false
        guard format !== upstreamFormat else { return false }

        if !sharedSampleMetadata.isEmpty, sharedSampleMetadata.last?.1 == format {
            upstreamFormat = sharedSampleMetadata.last?.1
        } else {
            upstreamFormat = format
        }

        allSamplesAreSyncSamples = format.mediaType == .audio
        return true
    }

    private func commitSample(time: Int64, sampleFlags: SampleFlags, offset: Int, size: Int) {
        lock.lock(); defer { lock.unlock() }
        if length > 0 {
            let previousSampleRelativeIndex = getRelativeIndex(offset: length - 1)
            assert(samples[previousSampleRelativeIndex].offset + samples[previousSampleRelativeIndex].size <= offset)
        }

        isLastSampleQueued = sampleFlags.contains(.lastSample)
        largestQueuedTimestamp = max(largestQueuedTimestamp, time)

        let relativeEndIndex = getRelativeIndex(offset: length)
        samples[relativeEndIndex] = .init(offset: offset, size: size, flags: sampleFlags, time: time)

        if sharedSampleMetadata.isEmpty || sharedSampleMetadata.last?.1 != upstreamFormat,
           let upstreamFormat {
            sharedSampleMetadata.append((getWriteIndex(), upstreamFormat))
        }

        length += 1

        if length == capacity {
            let newCapacity = capacity + 1000
            var newArray: [SampleWrapper] = Array(repeating: .init(), count: newCapacity)

            let beforeWrap = capacity - relativeFirstIndex
            let afterWrap = relativeFirstIndex
            newArray.replaceSubrange(0..<beforeWrap, with: samples[relativeFirstIndex..<capacity])
            newArray.replaceSubrange(beforeWrap..<(beforeWrap + afterWrap), with: samples[0..<afterWrap])

            samples = newArray
            relativeFirstIndex = 0
            capacity = newCapacity
        }
    }

    private func attemptSplice(time: Int64) -> Bool {
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
        sharedSampleMetadata.removeAll(where: { $0.0 >= discardFromIndex })
        if length != 0 {
            let relativeLastWriteIndex = getRelativeIndex(offset: length - 1)
            return samples[relativeLastWriteIndex].offset + samples[relativeLastWriteIndex].size
        }
        return 0
    }

    private func hasNextSample() -> Bool {
        return readPosition != length
    }

    private func findSampleBefore(relativeStartIndex: Int, length: Int, time: Int64, keyframe: Bool) -> Int {
        var sampleCountToTarget = -1
        var searchIndex = relativeStartIndex
        
        for i in 0..<length {
            if !keyframe || samples[searchIndex].flags.contains(.keyframe) {
                sampleCountToTarget = i

                if samples[searchIndex].time == time {
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

    private func findSampleAfter(relativeStartIndex: Int, length: Int, time: Int64, allowTimeBeyondBuffer: Bool) -> Int {
        var searchIndex = relativeStartIndex
        for i in 0..<length {
            if samples[searchIndex].time >= time {
                return i
            }
            searchIndex += 1
            if searchIndex == capacity {
                searchIndex = 0
            }
        }
        return allowTimeBeyondBuffer ? length : -1
    }

    private func countUnreadSamplesBefore(time: Int64) -> Int {
        var count = length
        var relativeSampleIndex = getRelativeIndex(offset: length - 1)

        while count > readPosition, samples[relativeSampleIndex].time >= time {
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
        sharedSampleMetadata.removeAll(where: { absoluteFirstIndex >= $0.0 + 1 })

        if length == 0 {
            let relativeLastDiscardIndex = (relativeFirstIndex == 0 ? capacity : relativeFirstIndex) - 1
            return samples[relativeLastDiscardIndex].offset + samples[relativeLastDiscardIndex].size
        } else {
            return samples[relativeFirstIndex].offset
        }
    }

    private func getLargestTimestamp(length: Int) -> Int64 {
        guard length > 0 else { return .min }

        var largestTimestamp = Int64.min
        var relativeSampleIndex = getRelativeIndex(offset: length - 1)

        for _ in 0..<length {
            largestTimestamp = max(largestTimestamp, samples[relativeSampleIndex].time)
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
    struct SampleExtrasHolder {
        let size: Int
        let offset: Int
    }

    private struct SampleWrapper {
        let offset: Int
        let size: Int
        let flags: SampleFlags
        let time: Int64

        init(offset: Int = 0, size: Int = 0, flags: SampleFlags = .init(), time: Int64 = 0) {
            self.offset = offset
            self.size = size
            self.flags = flags
            self.time = time
        }
    }
}

extension SampleQueue: CustomDebugStringConvertible {
    var debugDescription: String {
        upstreamFormat.debugDescription
    }
}
