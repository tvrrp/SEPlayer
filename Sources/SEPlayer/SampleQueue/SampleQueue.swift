//
//  SampleQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.07.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.SampleQueue
//  Copyright (C) 2019 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Extractor
import Foundation
import SEPlayerCommon

protocol SampleQueueDelegate: AnyObject {
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: AnyFormat)
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
            return samples[getRelativeIndex(offset: readPosition)].timingInfo.presentationTimeStamp
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

    private var downstreamFormat: AnyFormat? {
        didSet { downstreamFormatDescription = nil }
    }

    /// The description of the samples of the downstream format, made for the first of them.
    private var downstreamFormatDescription: CMFormatDescription?

    private var capacity: Int
    private var samples: ContiguousArray<SampleProperties>

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
    private var unadjustedUpstreamFormat: AnyFormat?
    private var upstreamFormat: AnyFormat?

    private var allSamplesAreSyncSamples: Bool
    private var sampleOffset: CMTime = .zero

    private var pendingSplice: Bool = false

    private var sharedSampleMetadata: SpannedData<AnyFormat>

    private var _backBufferDuration: CMTime?
    /// Media loaded beyond the queued samples but not extracted yet: it counts as buffered.
    private var unextractedDuration: CMTime = .zero

    /// - Parameter bufferedBytesCounter: Hears how many bytes of sample data the queue holds.
    init(queue: Queue, bufferedBytesCounter: BufferedBytesCounter? = nil) throws {
        self.queue = queue
        sampleDataQueue = SampleDataQueue(bufferedBytesCounter: bufferedBytesCounter)
        lock = RWLock()
        capacity = SampleQueue.sampleCapacityIncrement
        samples = ContiguousArray(repeating: SampleProperties(timingInfo: .invalid), count: capacity)
        sharedSampleMetadata = SpannedData<AnyFormat>(removeCallback: { _ in }) // TODO: fix
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
        return max(.zero, largestQueuedTimestamp - samples[readIndex].timingInfo.presentationTimeStamp)
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

    final func getUpstreamFormat() -> AnyFormat? {
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
        lock.withReadLock {
            length == 0 ? .negativeInfinity : samples[relativeFirstIndex].timingInfo.decodeTimeStamp
        }
    }

    func isReady(loadingFinished: Bool) -> Bool {
        lock.withReadLock {
            if !hasNextSample() {
                return loadingFinished
                    || isLastSampleQueued
                    || (upstreamFormat != nil && upstreamFormat != downstreamFormat)
            }

            return true
        }
    }

    func read(readFlags: ReadFlags, loadingFinished: Bool) throws -> SampleStreamReadResult {
        var backBufferDiscardPosition: Int?

        let item = try lock.withWriteLock {
            let item = try peekLocked(
                formatRequired: readFlags.contains(.requireFormat),
                loadingFinished: loadingFinished
            )
            guard case let .sample(sample, _) = item, !readFlags.contains(.peek) else {
                return item
            }

            readPosition += 1
            let time = sample.timingInfo.presentationTimeStamp
            if let backBuffer = _backBufferDuration, time.isNumeric {
                // `to: true` keeps samples up to the keyframe that anchors the back buffer,
                // ensuring seeks into the retained window always have a valid decode point.
                backBufferDiscardPosition = discardSampleMetadataLocked(
                    toTime: time - backBuffer, to: true, stopAtReadPosition: false
                )
            }
            return item
        }

        // SampleDataQueue calls stay outside the metadata lock: the data is read first, then discarded downstream.
        let buffer: CMSampleBuffer
        switch item {
        case .nothing:
            return .nothingRead
        case let .format(format):
            return .didReadFormat(format: format)
        case .endOfStream:
            buffer = try .endOfStream()
        case let .sample(sample, formatDescription):
            buffer = try CMSampleBuffer(
                dataBuffer: readFlags.contains(.omitSampleData)
                    ? nil
                    : sampleDataQueue.readBuffer(range: sample.dataRange),
                formatDescription: formatDescription,
                properties: sample
            )
            if let backBufferDiscardPosition {
                sampleDataQueue.discardDownstreamTo(absolutePosition: backBufferDiscardPosition)
            }
        }

        evaluateTriggers()
        return .didReadBuffer(buffer)
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

            if let offset = partialStartOffsetLocked(for: time) {
                startTime = time
                readPosition = offset
                return true
            }

            if !time.isNumeric || length == 0 || time < samples[relativeReadIndex].timingInfo.presentationTimeStamp
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
            let sample = samples[getRelativeIndex(offset: offset)]
            return .success(startPosition: sample.timingInfo.presentationTimeStamp)
        }
        if case .success = result { queue.async { self.evaluateTriggers() } }
        return result
    }

    /// The sample to read from to play from `time`, for samples that play in part: the one playing then, the samples
    /// before it that its format's decoder needs, and the samples before those which are trimmed whole.
    ///
    /// - Returns: `nil` when the samples play whole, or none of known duration plays at `time`.
    private func partialStartOffsetLocked(for time: CMTime) -> Int? {
        guard time.isNumeric, length > 0, upstreamFormat?.playsSamplesInPart == true else {
            return nil
        }
        let offset = findSampleBefore(
            relativeStartIndex: relativeFirstIndex,
            length: length,
            time: time,
            keyframe: false
        )
        guard offset >= 0 else { return nil }
        let timingInfo = samples[getRelativeIndex(offset: offset)].timingInfo
        guard timingInfo.duration.isNumeric, time < timingInfo.presentationTimeStamp + timingInfo.duration else {
            return nil
        }

        let format = sharedSampleMetadata.get(absoluteFirstIndex + offset)
        let prerollStart = offset - format.decoderPrerollSampleCount
        var start = offset
        while start > 0, sharedSampleMetadata.get(absoluteFirstIndex + start - 1) == format,
              start > prerollStart || !samples[getRelativeIndex(offset: start - 1)].hasOutput {
            start -= 1
        }
        return start
    }

    private func recoverySeekOffsetLocked(time: CMTime) -> Int? {
        if let offset = partialStartOffsetLocked(for: time) { return offset }
        guard time.isNumeric, length > 0,
              time >= samples[getRelativeIndex(offset: 0)].timingInfo.presentationTimeStamp else {
            return nil
        }
        let last = samples[getRelativeIndex(offset: length - 1)].timingInfo
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
            if !hasNextSample() || time < samples[relativeReadIndex].timingInfo.presentationTimeStamp {
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
    func getAdjustedUpstreamFormat(_ format: AnyFormat) -> AnyFormat {
        var format = format
        // Cues timed from an offset are timed from the offset of the samples too.
        if sampleOffset != .zero, let subsampleOffset = format.text?.subsampleOffset {
            format.text?.subsampleOffset = subsampleOffset + sampleOffset.seconds
        }
        return format
    }

    // MARK: - Writing, from the task that loads

    func sampleData(data: CMBlockBuffer) {
        sampleDataQueue.loadSampleData(buffer: data)
    }

    func setFormat(_ format: AnyFormat) {
        lock.withWriteLock { setFormatLocked(format) }
    }

    final func invalidateUpstreamFormatAdjustment() {
        lock.withWriteLock { upstreamFormatAdjustmentRequired = true }
    }

    func sampleMetadata(_ properties: SampleProperties) throws {
        // Only the extractor writes, and the upstream is discarded only while nothing loads: the value holds until the
        // sample is committed, and is taken before the lock (avoids calling into SampleDataQueue while locked).
        let range = properties.dataRange
        let absoluteOffset = sampleDataQueue.getTotalBytesWritten() - range.count - range.startIndex

        let committed: Bool = lock.withWriteLock {
            if upstreamFormatAdjustmentRequired, let unadjustedUpstreamFormat {
                setFormatLocked(unadjustedUpstreamFormat)
            }

            var sample = properties
            if upstreamKeyframeRequired {
                guard sample.isKeyframe else { return false }
                upstreamKeyframeRequired = false
            }

            // In the queue, a sample's bytes are where the data queue has them.
            sample.dataRange = absoluteOffset ..< absoluteOffset + range.count
            let presentationTime = sample.timingInfo.presentationTimeStamp + sampleOffset
            sample.timingInfo.presentationTimeStamp = presentationTime
            if sample.timingInfo.decodeTimeStamp.isNumeric {
                // Shifted with the presentation time: the output decode time keeps their difference.
                sample.timingInfo.decodeTimeStamp = sample.timingInfo.decodeTimeStamp + sampleOffset
            }
            if allSamplesAreSyncSamples {
                if isBeforeStartLocked(sample.timingInfo) { return false }
                // TODO: log bad data
                sample.isKeyframe = true
            }

            if pendingSplice {
                if !properties.isKeyframe || !attemptSpliceLocked(time: presentationTime) {
                    return false
                }
                pendingSplice = false
            }

            commitSampleLocked(sample)
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

    func setFormatLocked(_ format: AnyFormat) {
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
        if length == 0 || toTime < samples[relativeFirstIndex].timingInfo.presentationTimeStamp { return nil }

        let searchLength = stopAtReadPosition && readPosition != length ? readPosition + 1 : length
        let discardCount = findSampleBefore(
            relativeStartIndex: relativeFirstIndex,
            length: searchLength,
            time: toTime,
            keyframe: keyframe
        )

        return discardCount == -1 ? nil : discardSamples(discardCount: discardCount)
    }

    /// What a read finds at the read position.
    enum ReadItem {
        case nothing
        case format(AnyFormat)
        case sample(SampleProperties, CMFormatDescription)
        case endOfStream
    }

    func peekLocked(formatRequired: Bool, loadingFinished: Bool) throws -> ReadItem {
        if !hasNextSample() {
            if loadingFinished || isLastSampleQueued {
                return .endOfStream
            } else if let upstreamFormat, formatRequired || upstreamFormat != downstreamFormat {
                downstreamFormat = upstreamFormat
                return .format(upstreamFormat)
            } else {
                return .nothing
            }
        }

        let format = sharedSampleMetadata.get(getReadIndexLocked())
        if formatRequired || format != downstreamFormat {
            downstreamFormat = format
            return .format(format)
        }

        var sample = samples[getRelativeIndex(offset: readPosition)]
        if readPosition == (length - 1) && (loadingFinished || isLastSampleQueued) {
            sample.isLastSample = true
        }
        if format.playsSamplesInPart, startTime.isNumeric {
            // The sample playing at the start time plays from it, and those before it only prime the decoder.
            sample.trim(to: CMTimeRange(start: startTime, end: .positiveInfinity))
        }

        let formatDescription = try downstreamFormatDescription ?? format.formatDescription()
        downstreamFormatDescription = formatDescription
        return .sample(sample, formatDescription)
    }

    /// Whether a sample that decoding can start at isn't needed to play from the start time: it starts before it, or,
    /// when samples play in part, it ends before the samples the decoder needs ahead of the start time.
    func isBeforeStartLocked(_ timingInfo: CMSampleTimingInfo) -> Bool {
        guard let upstreamFormat, upstreamFormat.playsSamplesInPart,
              timingInfo.duration.isNumeric, timingInfo.duration > .zero else {
            return timingInfo.presentationTimeStamp < startTime
        }
        let preroll = CMTimeMultiply(
            timingInfo.duration,
            multiplier: Int32(upstreamFormat.decoderPrerollSampleCount)
        )
        return timingInfo.presentationTimeStamp + timingInfo.duration + preroll <= startTime
    }

    func setUpstreamFormatLocked(_ format: AnyFormat) -> Bool {
        upstreamFormatRequired = false
        guard format != upstreamFormat else { return false }

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

    func commitSampleLocked(_ sample: SampleProperties) {
        if length > 0 {
            let previousSampleRelativeIndex = getRelativeIndex(offset: length - 1)
            assert(samples[previousSampleRelativeIndex].dataRange.upperBound <= sample.dataRange.lowerBound)
        }

        isLastSampleQueued = sample.isLastSample
        largestQueuedTimestamp = max(largestQueuedTimestamp, sample.timingInfo.presentationTimeStamp)

        let relativeEndIndex = getRelativeIndex(offset: length)
        samples[relativeEndIndex] = sample

        if sharedSampleMetadata.isEmpty || sharedSampleMetadata.getEndValue() != upstreamFormat {
            if let upstreamFormat {
                sharedSampleMetadata.appendSpan(startKey: getWriteIndexLocked(), value: upstreamFormat)
            }
        }

        length += 1

        if length == capacity {
            let newCapacity = capacity + SampleQueue.sampleCapacityIncrement
            var newArray = ContiguousArray(
                repeating: SampleProperties(timingInfo: .invalid),
                count: newCapacity
            )

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
            return samples[relativeLastWriteIndex].dataRange.upperBound
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
            if samples[searchIndex].timingInfo.presentationTimeStamp <= time,
               !keyframe || samples[searchIndex].isKeyframe {
                sampleCountToTarget = i

                if samples[searchIndex].timingInfo.presentationTimeStamp == time {
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
            if samples[searchIndex].timingInfo.presentationTimeStamp >= time {
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

        while count > readPosition, samples[relativeSampleIndex].timingInfo.presentationTimeStamp >= time {
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
            return samples[relativeLastDiscardIndex].dataRange.upperBound
        } else {
            return samples[relativeFirstIndex].dataRange.lowerBound
        }
    }

    func getLargestTimestamp(length: Int) -> CMTime {
        guard length > 0 else { return .negativeInfinity }

        var largestTimestamp = CMTime.negativeInfinity
        var relativeSampleIndex = getRelativeIndex(offset: length - 1)

        for _ in 0 ..< length {
            largestTimestamp = max(largestTimestamp, samples[relativeSampleIndex].timingInfo.presentationTimeStamp)
            if samples[relativeSampleIndex].isKeyframe {
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
}

extension SampleQueue: CustomDebugStringConvertible {
    var debugDescription: String {
        "\(upstreamFormat!)"
    }
}
