//
//  SampleQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.07.2026.
//

import CoreMedia
import Extractor
import Foundation
import SEPlayerCommon

protocol SampleQueueDelegate: AnyObject {
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: Format)
}

class SampleQueue: TriggerableQueue, TrackOutput {
    weak var delegate: SampleQueueDelegate?

    /// The queued samples ahead of the read position, and the media loaded beyond them that is not extracted yet.
    override var bufferedAheadDuration: CMTime {
        lock.withReadLock { queuedAheadDurationLocked() + unextractedDuration }
    }

    /// The queued samples ahead of the read position.
    final var queuedAheadDuration: CMTime {
        lock.withReadLock { queuedAheadDurationLocked() }
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

    /// Samples to read, or the end of the stream once loading has finished.
    override var hasReadableSamples: Bool {
        readableSampleCount > 0 || lock.withReadLock { isLoadingFinished }
    }

    override var isEndOfData: Bool {
        lock.withReadLock { (isLastSampleQueued || isLoadingFinished) && readPosition == length }
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
    /// Set by the media period once nothing more will be loaded. The last sample may never arrive,
    /// e.g. after a seek to the very end, when every sample is before the start time.
    private var isLoadingFinished: Bool = false
    private var upstreamKeyframeRequired: Bool
    private var upstreamFormatRequired: Bool

    private var upstreamFormatAdjustmentRequired = false
    private var unadjustedUpstreamFormat: Format?
    private var upstreamFormat: Format?

    private var allSamplesAreSyncSamples: Bool
    private var sampleOffset: CMTime = .zero

    private var pendingSplice: Bool = false

    private var sharedSampleMetadata: SpannedData<Format>

    private var _backBufferDuration: CMTime?
    /// Media loaded beyond the queued samples but not extracted yet: it counts as buffered.
    private var unextractedDuration: CMTime = .zero

    /// - Parameter allocator: Hears how many bytes of sample data the queue holds.
    init(queue: Queue, allocator: Allocator? = nil) throws {
        self.queue = queue
        sampleDataQueue = SampleDataQueue(allocator: allocator)
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
        sampleDataQueue.reset()
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
            isLoadingFinished = false
            unextractedDuration = .zero
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

    /// Wakes readers waiting for data, so they read the end of the stream.
    final func setLoadingFinished(_ isLoadingFinished: Bool) {
        let changed = lock.withWriteLock {
            defer { self.isLoadingFinished = isLoadingFinished }
            return self.isLoadingFinished != isLoadingFinished
        }
        if changed { evaluateTriggers() }
    }

    /// How far behind the latest read samples stay, for media periods that discard as the renderers read: enough for
    /// renderers that read ahead of playback, and for a seek back a little.
    static let readBackBufferDuration = CMTime(value: 10, timescale: 1)

    /// Sets the media loaded beyond the queued samples but not extracted yet.
    ///
    /// - Returns: Whether it changed. The caller then evaluates the triggers, outside its own locks.
    @discardableResult
    final func setUnextractedDuration(_ duration: CMTime) -> Bool {
        lock.withWriteLock {
            guard unextractedDuration != duration else { return false }
            unextractedDuration = duration
            return true
        }
    }

    final func setStartTime(_ startTime: CMTime) {
        lock.withWriteLock { self.startTime = startTime }
    }

    final func splice() {
        lock.withWriteLock { pendingSplice = true }
    }

    private func queuedAheadDurationLocked() -> CMTime {
        guard readPosition < length else { return .zero }
        let readIndex = getRelativeIndex(offset: readPosition)
        return max(.zero, largestQueuedTimestamp - samples[readIndex].time.presentationTimeStamp)
    }

    final func getWriteIndex() -> Int {
        lock.withReadLock { getWriteIndexLocked() }
    }

    final func discardUpstreamSamples(discardFromIndex: Int) throws {
        let totalBytesWritten = lock.withWriteLock {
            SELogger.debug(.sampleQueue, "Discarding \(getWriteIndexLocked() - discardFromIndex) samples from \(discardFromIndex) on")
            return
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
                to: sampleDataQueue.readBuffer(range: dataRange)
            )
        }

        if performBackBufferDiscard {
            sampleDataQueue.discardDownstreamTo(absolutePosition: backBufferDiscardPosition)
        }

        if case .didReadBuffer = result {
            evaluateTriggers()
        }

        return result
    }

    @discardableResult
    func seek(to sampleIndex: Int) -> Bool {
        let result: Bool = lock.withWriteLock {
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
            let relativeReadIndex = getRelativeIndex(offset: 0)

            if !time.isNumeric || length == 0 || time < samples[relativeReadIndex].time.presentationTimeStamp
                || time > largestQueuedTimestamp && !allowTimeBeyondBuffer {
                return false
            }

            let offset = if allSamplesAreSyncSamples {
                findSampleAfter(
                    relativeStartIndex: relativeReadIndex,
                    length: length,
                    time: time,
                    allowTimeBeyondBuffer: allowTimeBeyondBuffer
                )
            } else {
                findSampleBefore(
                    relativeStartIndex: relativeReadIndex,
                    length: length,
                    time: time,
                    keyframe: true
                )
            }

            guard offset != -1 else {
                return false
            }
            SELogger.verbose(.sampleQueue, "Seek to \(time.seconds) reads from sample \(offset) of \(length)")
            startTime = time
            readPosition = offset
            return true
        }
        if result { queue.async { self.evaluateTriggers() } }
        return result
    }

    func canSeekWithinBuffer(to time: CMTime) -> Bool {
        lock.withReadLock { recoverySeekOffsetLocked(time: time) != nil }
    }

    func seekWithinBuffer(to time: CMTime) -> SampleStreamSeekResult {
        let result: SampleStreamSeekResult = lock.withWriteLock {
            guard let offset = recoverySeekOffsetLocked(time: time) else {
                return .unavailable
            }
            readPosition = offset
            startTime = time
            downstreamFormat = nil
            return .success(startPosition: samples[getRelativeIndex(offset: offset)].time.presentationTimeStamp)
        }
        if case .success = result { queue.async { self.evaluateTriggers() } }
        return result
    }

    private func recoverySeekOffsetLocked(time: CMTime) -> Int? {
        guard time.isNumeric, length > 0,
              time >= samples[getRelativeIndex(offset: 0)].time.presentationTimeStamp else {
            return nil
        }
        let last = samples[getRelativeIndex(offset: length - 1)].time
        let lastEnd = last.presentationTimeStamp + (last.duration.isNumeric ? last.duration : .zero)
        guard time <= max(largestQueuedTimestamp, lastEnd) else { return nil }
        // Retain the packet/frame spanning the playhead; video also needs a valid decode point.
        let offset = findSampleBefore(
            relativeStartIndex: getRelativeIndex(offset: 0),
            length: length,
            time: time,
            keyframe: !allSamplesAreSyncSamples
        )
        return offset >= 0 ? offset : nil
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
        sampleDataQueue.discardDownstreamTo(absolutePosition: position)
    }

    final func discardToRead() throws {
        let position = lock.withWriteLock { discardSampleMetadataToReadLocked() }
        sampleDataQueue.discardDownstreamTo(absolutePosition: position)
    }

    final func discardToEnd() throws {
        let position = lock.withWriteLock { discardSampleMetadataToEndLocked() }
        sampleDataQueue.discardDownstreamTo(absolutePosition: position)
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

    // MARK: - Writing, from the task that loads

    func sampleData(data: CMBlockBuffer) {
        sampleDataQueue.loadSampleData(buffer: data)
    }

    func setFormat(_ format: Format) {
        lock.withWriteLock { setFormatLocked(format) }
    }

    final func invalidateUpstreamFormatAdjustment() {
        lock.withWriteLock { upstreamFormatAdjustmentRequired = true }
    }

    func sampleMetadata(time: CMSampleTimingInfo, flags: SampleFlags, range: Range<Int>) throws {
//        print("SAMPLE METADATA, pts = \(time.presentationTimeStamp.seconds), range = \(range)")
        // Only the extractor writes, and the upstream is discarded only while nothing loads: the value holds until the
        // sample is committed, and is taken before the lock (avoids calling into SampleDataQueue while locked).
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
                // Shifted with the presentation time: the output decode time keeps their difference.
                decodeTimeStamp: time.decodeTimeStamp.isNumeric ? time.decodeTimeStamp + sampleOffset : time.decodeTimeStamp
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
            SELogger.debug(.sampleQueue, "Format at sample \(getWriteIndexLocked()): \(adjustedUpstreamFormat)")
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
            } else if let upstreamFormat, formatRequired || upstreamFormat != downstreamFormat {
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

        return (.didReadBuffer(sampleBuffer), sampleInfo.offset ..< (sampleInfo.offset + sampleInfo.size))
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
            newArray.replaceSubrange(0 ..< beforeWrap, with: samples[relativeFirstIndex ..< capacity])
            newArray.replaceSubrange(beforeWrap ..< (beforeWrap + afterWrap), with: samples[0 ..< afterWrap])

            samples = newArray
            relativeFirstIndex = 0
            capacity = newCapacity
        }
    }

    func attemptSpliceLocked(time: CMTime) -> Bool {
        guard length != 0 else { return time > largestDiscardedTimestamp }
        guard getLargestReadTimestampLocked() < time else { return false }

        let retainCount = countUnreadSamplesBefore(time: time)
        SELogger.debug(.sampleQueue, "Splicing at \(time.seconds): \(length - retainCount) queued samples replaced")
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

        for i in 0 ..< length {
            // Samples are in decode order: one after a later one can still be before `time`.
            if samples[searchIndex].time.presentationTimeStamp <= time,
               !keyframe || samples[searchIndex].flags.contains(.keyframe) {
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
        for i in 0 ..< length {
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

        for _ in 0 ..< length {
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
