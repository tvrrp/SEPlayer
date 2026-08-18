//
//  SampleQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.07.2026.
//

import CoreMedia
import Foundation
import Extractor
import SEPlayerCommon

protocol SampleQueueDelegate: AnyObject {
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: Format)
}

class SampleQueue: TriggerableQueue, TrackOutput {
    weak var delegate: SampleQueueDelegate?

    var isolation: any Actor { queue.playerActor() }

    override var bufferedAheadDuration: CMTime {
        lock.withReadLock {
            guard readPosition < length else { return .zero }
            let readIndex = getRelativeIndex(offset: readPosition)
            return max(.zero, largestQueuedTimestamp - samples[readIndex].time.presentationTimeStamp)
        }
    }

    override var readableSampleCount: Int {
        lock.withReadLock { length - readPosition }
    }

    override var minReadableTimestamp: CMTime? {
        lock.withReadLock {
            guard readPosition < length else { return nil }
            return samples[getRelativeIndex(offset: readPosition)].time.presentationTimeStamp
        }
    }

    override var hasReadableSamples: Bool { readableSampleCount > 0 }

    override var isEndOfData: Bool {
        lock.withReadLock { isLastSampleQueued && readPosition == length }
    }

    override var backBufferDuration: CMTime? {
        get { lock.withReadLock { _backBufferDuration } }
        set { lock.withWriteLock { _backBufferDuration = newValue } }
    }

    private let queue: Queue
    private let sampleDataQueue: SampleDataQueue
    private let lock: RWLock

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

    init(queue: Queue) throws {
        self.queue = queue
        sampleDataQueue = try SampleDataQueue(queue: queue)
        lock = RWLock()
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

    func release() throws { try reset(resetUpstreamFormat: true) }
    final func reset() throws { try reset(resetUpstreamFormat: false) }

    func reset(resetUpstreamFormat: Bool) throws {
        try sampleDataQueue.reset()
        lock.withWriteLock {
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
        // NOTE: trigger evaluation re-enters the read lock via the overridden
        // properties, so it must run *outside* the write lock (rwlock is not recursive).
//        queue.async {
//            self.fireResetTriggers()
//            self.evaluateTriggers()
//        }
        fireResetTriggers()
        evaluateTriggers()
    }

    final func setStartTime(_ startTime: CMTime) {
        lock.withWriteLock { self.startTime = startTime }
    }

    final func splice() {
        lock.withWriteLock { pendingSplice = true }
    }

    final func getWriteIndex() -> Int {
        lock.withReadLock { getWriteIndexLocked() }
    }

    final func discardUpstreamSamples(discardFromIndex: Int) throws {
        let totalBytesWritten = lock.withWriteLock {
            discardUpstreamSampleMetadataLocked(discardFromIndex: discardFromIndex)
        }
        try sampleDataQueue.discardUpstreamSampleBytes(totalBytesWritten: totalBytesWritten)
    }

    final func discardUpstreamFrom(time: CMTime) throws {
        let totalBytesWritten: Int? = lock.withWriteLock {
            guard length > 0 else { return nil }
            let retainCount = countUnreadSamplesBefore(time: time)
            return discardUpstreamSampleMetadataLocked(discardFromIndex: absoluteFirstIndex + retainCount)
        }
        guard let totalBytesWritten else { return }
        try sampleDataQueue.discardUpstreamSampleBytes(totalBytesWritten: totalBytesWritten)
    }

    func preRelease() throws {
        try discardToEnd()
    }

    func maybeThrowError() throws {}

    final func getFirstIndex() -> Int {
        lock.withReadLock { absoluteFirstIndex }
    }

    final func getReadIndex() -> Int {
        lock.withReadLock { getReadIndexLocked() }
    }

    final func getUpstreamFormat() -> Format? {
        lock.withReadLock { upstreamFormatRequired ? nil : upstreamFormat }
    }

    override final func getLargestQueuedTimestamp() -> CMTime {
        lock.withReadLock { largestQueuedTimestamp }
    }

    final func getLargestReadTimestamp() -> CMTime {
        lock.withReadLock { getLargestReadTimestampLocked() }
    }

    final func lastSampleQueued() -> Bool {
        lock.withReadLock { isLastSampleQueued }
    }

    final func getFirstTimestamp() -> CMTime {
        lock.withReadLock { length == 0 ? .negativeInfinity : samples[relativeFirstIndex].time.decodeTimeStamp }
    }

    func isReady(loadingFinished: Bool) -> Bool {
        lock.withReadLock {
            if !hasNextSample() {
                return loadingFinished
                    || isLastSampleQueued
                    || (upstreamFormat != nil && upstreamFormat != downstreamFormat)
            }

            if sharedSampleMetadata.get(getReadIndexLocked()) != downstreamFormat {
                return true
            }

            return true
        }
    }

    func read(readFlags: ReadFlags, loadingFinished: Bool) throws -> SampleStreamReadResult {
        var dataRange: Range<Int>?
        var performBackBufferDiscard = false
        var backBufferDiscardPosition: Int?

        let result: SampleStreamReadResult = try lock.withWriteLock {
            let (result, range) = try peekSampleMetadataLocked(
                formatRequired: readFlags.contains(.requireFormat),
                loadingFinished: loadingFinished
            )

            if case let .didReadBuffer(sampleBuffer) = result, let range,
               !sampleBuffer.flags.contains(.endOfStream) {
                let peek = readFlags.contains(.peek)
                if !readFlags.contains(.omitSampleData) {
                    dataRange = range
                }

                if !peek { readPosition += 1 }

                if !peek,
                   let backBuffer = _backBufferDuration,
                   sampleBuffer.presentationTimeStamp.isNumeric {
                    let discardThreshold = sampleBuffer.presentationTimeStamp - backBuffer
                    // `to: true` keeps samples up to the keyframe that anchors the back buffer,
                    // ensuring seeks into the retained window always have a valid decode point.
                    performBackBufferDiscard = true
                    backBufferDiscardPosition = discardSampleMetadataLocked(
                        toTime: discardThreshold, to: true, stopAtReadPosition: false
                    )
                }
            }

            return result
        }

        // SampleDataQueue calls stay outside the metadata lock, matching the original
        // locking granularity: readBuffer first, then the downstream discard.
        if case let .didReadBuffer(sampleBuffer) = result, let dataRange,
           !sampleBuffer.flags.contains(.endOfStream) {
            try sampleBuffer.setDataBuffer(
                sampleDataQueue.readBuffer(range: dataRange)
            )
        }

        if performBackBufferDiscard {
            try sampleDataQueue.discardDownstreamTo(absolutePosition: backBufferDiscardPosition)
        }

        if case .didReadBuffer(_) = result {
            evaluateTriggers()
        }

        return result
    }

    @discardableResult
    func seek(to sampleIndex: Int) -> Bool {
        let result: Bool = lock.withWriteLock {
            readPosition = 0
            if sampleIndex < absoluteFirstIndex || sampleIndex > absoluteFirstIndex + length {
                return false
            }
            startTime = .negativeInfinity
            readPosition = sampleIndex - absoluteFirstIndex
            return true
        }
        if result { queue.async { self.evaluateTriggers() } }
        return result
    }

    @discardableResult
    func seek(time: CMTime, allowTimeBeyondBuffer: Bool) -> Bool {
        let result: Bool = lock.withWriteLock {
            readPosition = 0
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
        if result { queue.async { self.evaluateTriggers() } }
        return result
    }

    final func getSkipCount(time: CMTime, allowEndOfQueue: Bool) -> Int {
        lock.withReadLock {
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
    }

    final func skip(count: Int) {
        lock.withWriteLock {
            assert(count >= 0 && readPosition + count <= length)
            readPosition += count
        }
    }

    final func discard(toTime: CMTime, to keyframe: Bool, stopAtReadPosition: Bool) throws {
        let position = lock.withWriteLock {
            discardSampleMetadataLocked(toTime: toTime, to: keyframe, stopAtReadPosition: stopAtReadPosition)
        }
        try sampleDataQueue.discardDownstreamTo(absolutePosition: position)
    }

    final func discardToRead() throws {
        let position = lock.withWriteLock { discardSampleMetadataToReadLocked() }
        try sampleDataQueue.discardDownstreamTo(absolutePosition: position)
    }

    final func discardToEnd() throws {
        let position = lock.withWriteLock { discardSampleMetadataToEndLocked() }
        try sampleDataQueue.discardDownstreamTo(absolutePosition: position)
    }

    func setSampleOffsetTime(_ sampleOffsetTime: CMTime) {
        lock.withWriteLock {
            guard sampleOffsetTime != sampleOffset else { return }
            sampleOffset = sampleOffsetTime
            upstreamFormatAdjustmentRequired = true
        }
    }

    func discardSampleMetadataToRead() -> Int? {
        lock.withWriteLock { discardSampleMetadataToReadLocked() }
    }

    func discardSampleMetadataToEnd() -> Int? {
        lock.withWriteLock { discardSampleMetadataToEndLocked() }
    }

    /// Must be called with the write lock held (invoked from the `setFormat` path).
    func getAdjustedUpstreamFormat(_ format: Format) -> Format {
        var format = format
        if sampleOffset != .zero, format.subsampleOffset != Format.offsetSampleRelative {
            format = format.buildUpon()
                .setSubsampleOffset(sampleOffset)
                .build()
        }
        return format
    }

    func sampleData(data: CMBlockBuffer, isolation: isolated any Actor) throws {
        try sampleDataQueue.loadSampleData(buffer: data, isolation: isolation)
    }

    func setFormat(_ format: Format, isolation: isolated any Actor) {
        lock.withWriteLock { setFormatLocked(format) }
    }

    final func invalidateUpstreamFormatAdjustment() {
        lock.withWriteLock { upstreamFormatAdjustmentRequired = true }
    }

    func sampleMetadata(time: CMSampleTimingInfo, flags: SampleFlags, range: Range<Int>, isolation: isolated any Actor) throws {
//        print("SAMPLE METADATA, pts = \(time.presentationTimeStamp.seconds), range = \(range)")
        // Same writer isolation as loadSampleData, so this value is stable and can be
        // computed before taking the lock (avoids calling into SampleDataQueue while locked).
        let absoluteOffset = sampleDataQueue.getTotalBytesWritten() - range.count - range.startIndex

        let committed: Bool = lock.withWriteLock {
            if upstreamFormatAdjustmentRequired, let unadjustedUpstreamFormat {
                setFormatLocked(unadjustedUpstreamFormat)
            }

            let isKeyframe = flags.contains(.keyframe)
            var flags = flags
            if upstreamKeyframeRequired {
                guard isKeyframe else { return false }
                upstreamKeyframeRequired = false
            }

            let time = CMSampleTimingInfo(
                duration: time.duration,
                presentationTimeStamp: time.presentationTimeStamp + sampleOffset,
                decodeTimeStamp: time.decodeTimeStamp
            )
            if allSamplesAreSyncSamples {
                if time.presentationTimeStamp < startTime { return false }
                // TODO: log bad data
                flags.insert(.keyframe)
            }

            if pendingSplice {
                if !isKeyframe || !attemptSpliceLocked(time: time.presentationTimeStamp) {
                    return false
                }
                pendingSplice = false
            }

            commitSampleLocked(time: time, sampleFlags: flags, offset: absoluteOffset, size: range.count)
            return true
        }

//        queue.async { self.evaluateTriggers() }
        if committed { evaluateTriggers() }
    }
}

// MARK: - Unlocked implementations (caller must hold the appropriate lock)

private extension SampleQueue {
    func getWriteIndexLocked() -> Int {
        absoluteFirstIndex + length
    }

    func getReadIndexLocked() -> Int {
        absoluteFirstIndex + readPosition
    }

    func getLargestReadTimestampLocked() -> CMTime {
        max(largestDiscardedTimestamp, getLargestTimestamp(length: readPosition))
    }

    func setFormatLocked(_ format: Format) {
        let adjustedUpstreamFormat = getAdjustedUpstreamFormat(format)
        upstreamFormatAdjustmentRequired = false
        unadjustedUpstreamFormat = format
        if setUpstreamFormatLocked(adjustedUpstreamFormat) {
            queue.justDispatch { self.delegate?.sampleQueue(self, didChange: adjustedUpstreamFormat) }
        }
    }

    func discardSampleMetadataToReadLocked() -> Int? {
        guard readPosition != 0 else { return nil }
        return discardSamples(discardCount: readPosition)
    }

    func discardSampleMetadataToEndLocked() -> Int? {
        guard length != 0 else { return nil }
        return discardSamples(discardCount: length)
    }

    func discardSampleMetadataLocked(toTime: CMTime, to keyframe: Bool, stopAtReadPosition: Bool) -> Int? {
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

    func peekSampleMetadataLocked(
        formatRequired: Bool,
        loadingFinished: Bool
    ) throws -> (result: SampleStreamReadResult, range: Range<Int>?) {
        if !hasNextSample() {
            if loadingFinished || isLastSampleQueued {
                return try (.didReadBuffer(.createEndOfStream()), nil)
            } else if let upstreamFormat, (formatRequired || upstreamFormat != downstreamFormat) {
                downstreamFormat = upstreamFormat
                return (.didReadFormat(format: upstreamFormat), nil)
            } else {
                return (.nothingRead, nil)
            }
        }

        let format = sharedSampleMetadata.get(getReadIndexLocked())
        if formatRequired || format != downstreamFormat {
            downstreamFormat = format
            return (.didReadFormat(format: format), nil)
        }

        let relativeReadIndex = getRelativeIndex(offset: readPosition)
        let sampleInfo = samples[relativeReadIndex]
        var flags = sampleInfo.flags
        if readPosition == (length - 1) && (loadingFinished || isLastSampleQueued) {
            flags.insert(.lastSample)
        }

        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: nil,
            formatDescription: format.buildFormatDescription(),
            numSamples: 1,
            sampleTimings: [sampleInfo.time],
            sampleSizes: [sampleInfo.size]
        )

        sampleBuffer.flags = flags
//        if flags.contains(.firstSample) || flags.contains(.lastSample) {
//            sampleBuffer.attachments.merge([
//                CMSampleBuffer.AttachmentKey.postNotificationWhenConsumed.rawValue as String: [:]
//            ], mode: .shouldPropagate)
//        }

        return (.didReadBuffer(sampleBuffer), sampleInfo.offset..<(sampleInfo.offset + sampleInfo.size))
    }

    func setUpstreamFormatLocked(_ format: Format) -> Bool {
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

    func commitSampleLocked(time: CMSampleTimingInfo, sampleFlags: SampleFlags, offset: Int, size: Int) {
        if length > 0 {
            let previousSampleRelativeIndex = getRelativeIndex(offset: length - 1)
            assert(samples[previousSampleRelativeIndex].offset + samples[previousSampleRelativeIndex].size <= offset)
        }

        isLastSampleQueued = sampleFlags.contains(.lastSample)
        largestQueuedTimestamp = max(largestQueuedTimestamp, time.presentationTimeStamp)

        let relativeEndIndex = getRelativeIndex(offset: length)
        samples[relativeEndIndex] = .init(offset: offset, size: size, flags: sampleFlags, time: time)

        if sharedSampleMetadata.isEmpty || sharedSampleMetadata.getEndValue() != upstreamFormat {
            if let upstreamFormat {
                sharedSampleMetadata.appendSpan(startKey: getWriteIndexLocked(), value: upstreamFormat)
            }
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

    func attemptSpliceLocked(time: CMTime) -> Bool {
        guard length != 0 else { return time > largestDiscardedTimestamp }
        guard getLargestReadTimestampLocked() < time else { return false }

        let retainCount = countUnreadSamplesBefore(time: time)
        discardUpstreamSampleMetadataLocked(discardFromIndex: absoluteFirstIndex + retainCount)
        return true
    }

    @discardableResult
    func discardUpstreamSampleMetadataLocked(discardFromIndex: Int) -> Int {
        let discardCount = getWriteIndexLocked() - discardFromIndex
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

    func hasNextSample() -> Bool {
        readPosition != length
    }

    func findSampleBefore(relativeStartIndex: Int, length: Int, time: CMTime, keyframe: Bool) -> Int {
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

    func findSampleAfter(relativeStartIndex: Int, length: Int, time: CMTime, allowTimeBeyondBuffer: Bool) -> Int {
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

    func countUnreadSamplesBefore(time: CMTime) -> Int {
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

    func discardSamples(discardCount: Int) -> Int {
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

    func getLargestTimestamp(length: Int) -> CMTime {
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

    func getRelativeIndex(offset: Int) -> Int {
        let relativeIndex = relativeFirstIndex + offset
        return relativeIndex < capacity ? relativeIndex : relativeIndex - capacity
    }
}

extension SampleQueue {
    static let sampleCapacityIncrement: Int = 1000

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
