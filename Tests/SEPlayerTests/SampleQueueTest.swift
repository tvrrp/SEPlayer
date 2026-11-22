//
//  SampleQueueTest.swift
//  SEPlayer Tests
//
//  Created by Damir Yackupov on 03.11.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.SampleQueueTest
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

// swiftlint:disable file_length

import CoreMedia
@testable import SEPlayer
import Testing

@TestableSyncPlayerActor
class SampleQueueTest {
    private let allocationSize: Int = 16
    private lazy var format1 = buildFormat(id: "1")
    private lazy var format2 = buildFormat(id: "2")
    private lazy var format1Copy = buildFormat(id: "1")
    private lazy var formatSpliced = buildFormat(id: "spliced")
    private lazy var formatSyncSampleOnly1 = Self.linearPCMFormat(id: "sync1")
    private lazy var formatSyncSampleOnly2 = Self.linearPCMFormat(id: "sync2")

    private lazy var dataCapacity = allocationSize * 10
    private lazy var data = TestUtil.buildTestData(length: dataCapacity)

    private lazy var sampleSizes: [Int] = [
        allocationSize - 1,
        allocationSize - 2,
        allocationSize - 1,
        allocationSize - 1,
        allocationSize,
        allocationSize * 2,
        allocationSize * 2 - 2,
        allocationSize,
    ]

    private lazy var sampleOffsets: [Int] = [
        allocationSize * 9,
        allocationSize * 8 + 1,
        allocationSize * 7,
        allocationSize * 6 + 1,
        allocationSize * 5,
        allocationSize * 3,
        allocationSize + 1,
        0,
    ]

    private let sampleTimestamps: [Int64] = [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000]
    private let sampleFlags: [SampleProperties.Flags] = [.keyframe, [], [], [], .keyframe, [], [], []]
    private lazy var sampleFlagsSyncSamplesOnly = [SampleProperties.Flags](repeating: .keyframe, count: sampleFlags.count)
    private lazy var sampleFormats: [AnyFormat] = [format1, format1, format1, format1, format2, format2, format2, format2]
    private let dataSecondKeyframeIndex = 4
    private lazy var sampleFormatsSyncSamplesOnly: [AnyFormat] = [
        formatSyncSampleOnly1,
        formatSyncSampleOnly1,
        formatSyncSampleOnly1,
        formatSyncSampleOnly1,
        formatSyncSampleOnly2,
        formatSyncSampleOnly2,
        formatSyncSampleOnly2,
        formatSyncSampleOnly2,
    ]

    private let closeToCapacitySize = SampleQueue.sampleCapacityIncrement - 1

    private var sampleQueue: SampleQueue
    private let inputBuffer: TestInputBuffer

    init() throws {
        sampleQueue = try SampleQueue(queue: playerSyncQueue)
        inputBuffer = TestInputBuffer()
    }

    @Test
    func failedRecoveryAndOrdinarySeeksPreserveAdvancedCursor() throws {
        try writeTestData()
        sampleQueue.skip(count: 3)
        let original = sampleQueue.getReadIndex()
        #expect(sampleQueue.seekWithinBuffer(to: CMTime(value: -1, timescale: 1)) == .unavailable)
        #expect(sampleQueue.getReadIndex() == original)
        #expect(!sampleQueue.seek(time: CMTime(value: 100, timescale: 1), allowTimeBeyondBuffer: false))
        #expect(sampleQueue.getReadIndex() == original)
        #expect(!sampleQueue.seek(to: -1))
        #expect(sampleQueue.getReadIndex() == original)
    }

    @Test
    func recoverySeekRestoresVideoDecodePointAndFormat() throws {
        try writeTestData()
        sampleQueue.skip(count: sampleTimestamps.count)
        let result = sampleQueue.seekWithinBuffer(to: CMTime(value: 6500, timescale: 1_000_000))
        #expect(result == .success(startPosition: CMTime(value: 4000, timescale: 1_000_000)))
        try assertReadFormat(formatRequired: false, format: format2)
        #expect(sampleQueue.getReadIndex() == dataSecondKeyframeIndex)
    }

    @Test
    func recoverySeekIsRepeatableAndRetainsPacketBeforePlayhead() throws {
        try writeSyncSamplesOnlyTestData()
        sampleQueue.skip(count: sampleTimestamps.count)
        for _ in 0 ..< 2 {
            let result = sampleQueue.seekWithinBuffer(to: CMTime(value: 6500, timescale: 1_000_000))
            #expect(result == .success(startPosition: CMTime(value: 6000, timescale: 1_000_000)))
            #expect(sampleQueue.getReadIndex() == 6)
            sampleQueue.skip(count: 2)
        }
    }

    @Test(arguments: [true, false])
    func audioSeekKeepsPrerollAndTrimsThePacketAtTheTarget(buffered: Bool) throws {
        let format = SEPlayerTestRunner.audioFormat
        let target = CMTime(value: 25, timescale: 1000)
        let duration = CMTime(value: 10, timescale: 1000)
        sampleQueue.setFormat(format)
        if !buffered { sampleQueue.setStartTime(target) }
        for index in 0 ..< 4 {
            try sampleQueue.sampleData(data: [UInt8(index)], length: 1, isolation: TestableSyncPlayerActor.shared)
            let time = CMTime(value: Int64(index * 10), timescale: 1000)
            let timing = CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: time,
                decodeTimeStamp: .invalid
            )
            try sampleQueue.sampleMetadata(
                SampleProperties(
                    timingInfo: timing,
                    dataRange: 0 ..< 1,
                    flags: [.keyframe, .decodeOnly]
                )
            )
        }
        if buffered { #expect(sampleQueue.seek(time: target, allowTimeBeyondBuffer: false)) }
        try assertReadFormat(formatRequired: false, format: format)
        func readPacket() throws -> CMSampleBuffer {
            guard case let .didReadBuffer(buffer) = try sampleQueue.read(readFlags: [], loadingFinished: false) else {
                throw SampleBufferError.requiredParameterMissing
            }
            return buffer
        }
        let prime = try readPacket()
        let first = try readPacket()
        #expect(prime.presentationTimeStamp == duration)
        #expect(prime.outputDuration == .zero)
        #expect(first.outputPresentationTimeStamp == target)
        #expect(first.outputDuration == CMTime(value: 5, timescale: 1000))
        var batch = try #require(AudioPacketBatch(prime))
        #expect(batch.canAppend(first))
        batch.append(first)
        let output = try batch.makeSampleBuffer()
        #expect(output.numSamples == 2)
        #expect(output.outputPresentationTimeStamp == target)
        #expect(output.outputDuration == first.outputDuration)
        #expect(output.perSampleAttachments[1].bool(for: .doNotDisplay) == true)
    }

    @Test
    func capacityIncreases() throws {
        let numberOfSamplesToInput = 3 * SampleQueue.sampleCapacityIncrement + 1
        sampleQueue.setFormat(format1)
        try sampleQueue.sampleData(
            data: [UInt8](repeating: 0, count: numberOfSamplesToInput),
            length: numberOfSamplesToInput,
            isolation: TestableSyncPlayerActor.shared
        )

        for i in 0 ..< numberOfSamplesToInput {
            try sampleQueue.sampleMetadata(
                time: Int64(i * 1000),
                flags: .keyframe,
                size: 1,
                offset: numberOfSamplesToInput - i - 1
            )
        }
        try assertReadFormat(formatRequired: false, format: format1)

        for i in 0 ..< numberOfSamplesToInput {
            try assertReadSample(
                timeUs: Int64(i * 1000),
                isKeyFrame: true,
                sampleData: [UInt8](repeating: 0, count: 1),
                offset: 0,
                length: 1
            )
        }

        try assertReadNothing(formatRequired: false)
    }

    @Test
    func readWithoutWrite() throws {
        try assertNoSamplesToRead(endFormat: nil)
    }

    @Test
    func peekConsumesDownstreamFormat() throws {
        sampleQueue.setFormat(format1)
        clearInputBuffer()
        var result = try sampleQueue.read(
            buffer: inputBuffer,
            readFlags: .peek,
            loadingFinished: false
        )

        #expect({
            if case let .didReadFormat(readedFormat) = result {
                readedFormat == format1
            } else {
                false
            }
        }())

        result = try sampleQueue.read(
            buffer: inputBuffer,
            readFlags: .peek,
            loadingFinished: false
        )
        #expect(result == .nothingRead)
    }

    @Test
    func equalFormatsDeduplicated() throws {
        sampleQueue.setFormat(format1)
        try assertReadFormat(formatRequired: false, format: format1)
        // If the same format is written then it should not cause a format change on the read side.
        sampleQueue.setFormat(format1)
        try assertNoSamplesToRead(endFormat: format1)
        // The same applies for a format that's equal (but a different object).
        sampleQueue.setFormat(format1Copy)
        try assertNoSamplesToRead(endFormat: format1)
    }

    @Test
    func multipleFormatsDeduplicated() throws {
        sampleQueue.setFormat(format1)
        try sampleQueue.sampleData(data: data, length: allocationSize, isolation: TestableSyncPlayerActor.shared)
        try sampleQueue.sampleMetadata(time: 0, flags: .keyframe, size: allocationSize, offset: 0)
        // Writing multiple formats should not cause a format change on the read side, provided the last
        // format to be written is equal to the format of the previous sample.
        sampleQueue.setFormat(format2)
        sampleQueue.setFormat(format1Copy)
        try sampleQueue.sampleData(data: data, length: allocationSize, isolation: TestableSyncPlayerActor.shared)
        try sampleQueue.sampleMetadata(time: 1000, flags: .keyframe, size: allocationSize, offset: 0)

        try assertReadFormat(formatRequired: false, format: format1)
        try assertReadSample(
            timeUs: 0,
            isKeyFrame: true,
            sampleData: data,
            offset: 0,
            length: allocationSize
        )
        // Assert the second sample is read without a format change.
        try assertReadSample(
            timeUs: 1000,
            isKeyFrame: true,
            sampleData: data,
            offset: 0,
            length: allocationSize
        )

        // The same applies if the queue is empty when the formats are written.
        sampleQueue.setFormat(format2)
        sampleQueue.setFormat(format1)
        try sampleQueue.sampleData(data: data, length: allocationSize, isolation: TestableSyncPlayerActor.shared)
        try sampleQueue.sampleMetadata(time: 2000, flags: .keyframe, size: allocationSize, offset: 0)

        // Assert the third sample is read without a format change.
        try assertReadSample(
            timeUs: 2000,
            isKeyFrame: true,
            sampleData: data,
            offset: 0,
            length: allocationSize
        )
    }

    @Test
    func readSingleSamples() throws {
        try sampleQueue.sampleData(data: data, length: allocationSize, isolation: TestableSyncPlayerActor.shared)

        // Nothing to read without sample metadata
        try assertNoSamplesToRead(endFormat: nil)

        sampleQueue.setFormat(format1)

        // Read the format.
        try assertReadFormat(formatRequired: false, format: format1)
        // Nothing to read without sample metadata
        try assertNoSamplesToRead(endFormat: format1)

        try sampleQueue.sampleMetadata(time: 1000, flags: .keyframe, size: allocationSize, offset: 0)

        // If formatRequired, should read the format rather than the sample.
        try assertReadFormat(formatRequired: true, format: format1)
        // Otherwise should read the sample.
        try assertReadSample(timeUs: 1000, isKeyFrame: true, sampleData: data, offset: 0, length: allocationSize)
        try sampleQueue.discardToRead()

        // Nothing to read.
        try assertNoSamplesToRead(endFormat: format1)

        // Write a second sample followed by one byte that does not belong to it.
        try sampleQueue.sampleData(data: data, length: allocationSize, isolation: TestableSyncPlayerActor.shared)
        try sampleQueue.sampleMetadata(time: 2000, flags: [], size: allocationSize - 1, offset: 1)

        // If formatRequired, should read the format rather than the sample.
        try assertReadFormat(formatRequired: true, format: format1)
        // Try reading the sample
        try assertReadSample(timeUs: 2000, isKeyFrame: false, sampleData: data, offset: 0, length: allocationSize - 1)
        try sampleQueue.discardToRead()

        // Write metadata for a third sample containing the remaining byte.
        try sampleQueue.sampleMetadata(time: 3000, flags: [], size: 1, offset: 0)

        // If formatRequired, should read the format rather than the sample.
        try assertReadFormat(formatRequired: true, format: format1)
        // Try reading the sample
        try assertReadSample(timeUs: 3000, isKeyFrame: false, sampleData: data, offset: allocationSize - 1, length: 1)
        try sampleQueue.discardToRead()
    }

    @Test
    func readSingleSampleWithLoadingFinished() throws {
        try sampleQueue.sampleData(data: data, length: allocationSize, isolation: TestableSyncPlayerActor.shared)
        sampleQueue.setFormat(format1)
        try sampleQueue.sampleMetadata(time: 1000, flags: .keyframe, size: allocationSize, offset: 0)

        // If formatRequired, should read the format rather than the sample.
        try assertReadFormat(formatRequired: true, format: format1)
        try assertReadLastSample(timeUs: 1000, isKeyFrame: true, sampleData: data, offset: 0, length: allocationSize)

        try sampleQueue.discardToRead()
    }

    @Test
    func readMultiSamples() throws {
        try writeTestData()
        #expect(sampleQueue.getLargestQueuedTimestamp() == sampleTimestamps.last)
        try assertReadTestData()
        try sampleQueue.discardToEnd()
    }

    @Test
    func readMultiSamplesTwice() throws {
        try writeTestData()
        try writeTestData()
        try assertReadTestData(startFormat: format2)
        try assertReadTestData(startFormat: format2)
        try sampleQueue.discardToEnd()
    }

    @Test
    func readMultiWithSeek() throws {
        try writeTestData()
        try assertReadTestData()
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 8)

        sampleQueue.seek(to: 0)
        // Read again.
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 0)
        try assertReadTestData()
    }

    @Test
    func emptyQueueReturnsLoadingFinished() throws {
        try sampleQueue.sampleData(data: data, length: data.count, isolation: TestableSyncPlayerActor.shared)
        #expect(sampleQueue.isReady(loadingFinished: false) == false)
        #expect(sampleQueue.isReady(loadingFinished: true))
    }

    @Test
    func isReadyWithUpstreamFormatOnlyReturnsTrue() {
        sampleQueue.setFormat(format1)
        #expect(sampleQueue.isReady(loadingFinished: false))
    }

    @Test
    func seekAfterDiscard() throws {
        try writeTestData()
        try assertReadTestData()
        try sampleQueue.discardToRead()
        #expect(sampleQueue.getFirstIndex() == 8)
        #expect(sampleQueue.getReadIndex() == 8)

        sampleQueue.seek(to: 0)
        // Can't read again.
        #expect(sampleQueue.getFirstIndex() == 8)
        #expect(sampleQueue.getReadIndex() == 8)
        try assertReadEndOfStream(formatRequired: false)
    }

    @Test
    func skipToEnd() throws {
        try writeTestData()
        sampleQueue.skip(count: sampleQueue.getSkipCount(time: .max, allowEndOfQueue: true))
        try sampleQueue.discardToRead()
        // Despite skipping all samples, we should still read the last format, since this is the
        // expected format for a subsequent sample.
        try assertReadFormat(formatRequired: false, format: format2)
        // Once the format has been read, there's nothing else to read.
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func skipToEndRetainsUnassignedData() throws {
        sampleQueue.setFormat(format1)
        try sampleQueue.sampleData(data: data, length: allocationSize, isolation: TestableSyncPlayerActor.shared)
        sampleQueue.skip(count: sampleQueue.getSkipCount(time: .max, allowEndOfQueue: true))
        try sampleQueue.discardToRead()
        // We should be able to read the format.
        try assertReadFormat(formatRequired: false, format: format1)
        // Once the format has been read, there's nothing else to read.
        try assertNoSamplesToRead(endFormat: format1)

        try sampleQueue.sampleMetadata(time: 0, flags: .keyframe, size: allocationSize, offset: 0)
        // Once the metadata has been written, check the sample can be read as expected.
        try assertReadSample(timeUs: 0, isKeyFrame: true, sampleData: data, offset: 0, length: allocationSize)
        try assertNoSamplesToRead(endFormat: format1)
        try sampleQueue.discardToEnd()
    }

    @Test
    func skipToBeforeBuffer() throws {
        try writeTestData()
        let skipCount = sampleQueue.getSkipCount(time: sampleTimestamps[0] - 1, allowEndOfQueue: false)
        // Should have no effect (we're already at the first frame).
        #expect(skipCount == 0)
        sampleQueue.skip(count: skipCount)
        try assertReadTestData()
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func skipToStartOfBuffer() throws {
        try writeTestData()
        let skipCount = sampleQueue.getSkipCount(time: sampleTimestamps[0], allowEndOfQueue: false)
        // Should have no effect (we're already at the first frame).
        #expect(skipCount == 0)
        sampleQueue.skip(count: skipCount)
        try assertReadTestData()
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func skipToEndOfBuffer() throws {
        try writeTestData()
        let skipCount = try sampleQueue.getSkipCount(time: #require(sampleTimestamps.last), allowEndOfQueue: false)
        #expect(skipCount == 4)
        sampleQueue.skip(count: 4)
        try assertReadTestData(firstSampleIndex: dataSecondKeyframeIndex)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func skipToAfterBuffer() throws {
        try writeTestData()
        let skipCount = try sampleQueue.getSkipCount(time: #require(sampleTimestamps.last) + 1, allowEndOfQueue: false)
        // Should advance to 2nd keyframe (the 4th frame).
        #expect(skipCount == 4)
        sampleQueue.skip(count: 4)
        try assertReadTestData(firstSampleIndex: dataSecondKeyframeIndex)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func seekToBeforeBufferNotAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeTestData()

        let success = sampleQueue.seek(to: sampleTimestamps[0] - 1, allowTimeBeyondBuffer: false)

        #expect(success == false && sampleQueue.getReadIndex() == closeToCapacitySize)
        try assertReadTestData()
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func seekToStartOfBufferNotAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeTestData()
        let success = sampleQueue.seek(to: sampleTimestamps[0], allowTimeBeyondBuffer: false)

        #expect(success && sampleQueue.getReadIndex() == closeToCapacitySize)
        try assertReadTestData()
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func seekToEndOfBufferNotAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeTestData()

        let success = try sampleQueue.seek(
            to: #require(sampleTimestamps.last),
            allowTimeBeyondBuffer: false
        )

        #expect(success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize + 4)

        try assertReadTestData(
            firstSampleIndex: dataSecondKeyframeIndex,
            sampleCount: sampleTimestamps.count - dataSecondKeyframeIndex,
            sampleOffsetUs: 0
        )
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func seekToAfterBufferNotAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeTestData()

        let success = try sampleQueue.seek(
            to: #require(sampleTimestamps.last) + 1,
            allowTimeBeyondBuffer: false
        )

        #expect(!success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize)

        try assertReadTestData()
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func seekToAfterBufferAllowedNotAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeTestData()

        let success = try sampleQueue.seek(
            to: #require(sampleTimestamps.last) + 1,
            allowTimeBeyondBuffer: true
        )

        #expect(success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize + 4)

        try assertReadTestData(
            firstSampleIndex: dataSecondKeyframeIndex,
            sampleCount: sampleTimestamps.count - dataSecondKeyframeIndex,
            sampleOffsetUs: 0
        )
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func seekToEndAndBackToStartNotAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeTestData()

        // Seek to end (exact last timestamp), expect jump to second keyframe window.
        var success = try sampleQueue.seek(
            to: #require(sampleTimestamps.last),
            allowTimeBeyondBuffer: false
        )

        #expect(success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize + 4)

        try assertReadTestData(
            firstSampleIndex: dataSecondKeyframeIndex,
            sampleCount: sampleTimestamps.count - dataSecondKeyframeIndex,
            sampleOffsetUs: 0
        )
        try assertNoSamplesToRead(endFormat: format2)

        // Seek back to the start (first timestamp).
        success = try sampleQueue.seek(
            to: #require(sampleTimestamps.first),
            allowTimeBeyondBuffer: false
        )

        #expect(success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize)

        try assertReadTestData()
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func seekToBeforeBufferAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeSyncSamplesOnlyTestData()

        let success = try sampleQueue.seek(
            to: #require(sampleTimestamps.first) - 1,
            allowTimeBeyondBuffer: false
        )

        #expect(!success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize)

        try assertReadSyncSampleOnlyTestData()
        try assertNoSamplesToRead(endFormat: formatSyncSampleOnly2)
    }

    @Test
    func seekToStartOfBufferAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeSyncSamplesOnlyTestData()

        let success = try sampleQueue.seek(
            to: #require(sampleTimestamps.first),
            allowTimeBeyondBuffer: false
        )

        #expect(success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize)

        try assertReadSyncSampleOnlyTestData()
        try assertNoSamplesToRead(endFormat: formatSyncSampleOnly2)
    }

    @Test
    func seekToEndOfBufferAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeSyncSamplesOnlyTestData()

        let success = try sampleQueue.seek(
            to: #require(sampleTimestamps.last),
            allowTimeBeyondBuffer: false
        )

        #expect(success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize + sampleTimestamps.count - 1)

        try assertReadSyncSampleOnlyTestData(
            firstSampleIndex: sampleTimestamps.count - 1,
            sampleCount: 1
        )
        try assertNoSamplesToRead(endFormat: formatSyncSampleOnly2)
    }

    @Test
    func seekToAfterBufferAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeSyncSamplesOnlyTestData()

        let success = try sampleQueue.seek(
            to: #require(sampleTimestamps.last) + 1,
            allowTimeBeyondBuffer: false
        )

        #expect(!success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize)

        try assertReadSyncSampleOnlyTestData()
        try assertNoSamplesToRead(endFormat: formatSyncSampleOnly2)
    }

    @Test
    func seekToAfterBufferAllowedAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeSyncSamplesOnlyTestData()

        let success = try sampleQueue.seek(
            to: #require(sampleTimestamps.last) + 1,
            allowTimeBeyondBuffer: true
        )

        #expect(success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize + sampleTimestamps.count)

        try assertReadFormat(formatRequired: false, format: formatSyncSampleOnly2)
        try assertNoSamplesToRead(endFormat: formatSyncSampleOnly2)
    }

    @Test
    func seekToEndAndBackToStartAllSamplesAreSyncSamples() throws {
        try writeAndDiscardPlaceholderSamples(sampleCount: closeToCapacitySize)
        try writeSyncSamplesOnlyTestData()

        // Seek to end (exact last timestamp).
        var success = try sampleQueue.seek(
            to: #require(sampleTimestamps.last),
            allowTimeBeyondBuffer: false
        )

        #expect(success)
        #expect(
            sampleQueue.getReadIndex()
                == closeToCapacitySize + sampleTimestamps.count - 1
        )

        try assertReadSyncSampleOnlyTestData(
            firstSampleIndex: sampleTimestamps.count - 1,
            sampleCount: 1
        )
        try assertNoSamplesToRead(endFormat: formatSyncSampleOnly2)

        // Seek back to the start.
        success = try sampleQueue.seek(
            to: #require(sampleTimestamps.first),
            allowTimeBeyondBuffer: false
        )

        #expect(success)
        #expect(sampleQueue.getReadIndex() == closeToCapacitySize)

        try assertReadSyncSampleOnlyTestData()
        try assertNoSamplesToRead(endFormat: formatSyncSampleOnly2)
    }

    @Test
    func setStartTimeUsAllSamplesAreSyncSamplesDiscardsOnWriteSide() throws {
        try sampleQueue.setStartTime(#require(sampleTimestamps.last))
        try writeSyncSamplesOnlyTestData()

        #expect(sampleQueue.getReadIndex() == 0)

        try assertReadFormat(formatRequired: false, format: formatSyncSampleOnly2)

        try assertReadSample(
            timeUs: sampleTimestamps[7],
            isKeyFrame: true,
            sampleData: data,
            offset: data.count - sampleOffsets[7] - sampleSizes[7],
            length: sampleSizes[7]
        )
    }

    @Test
    func setStartTimeUsNotAllSamplesAreSyncSamplesDiscardsOnReadSide() throws {
        try sampleQueue.setStartTime(#require(sampleTimestamps.last))
        try writeTestData()

        #expect(sampleQueue.getReadIndex() == 0)

        try assertReadTestData(
            firstSampleIndex: 0,
            sampleCount: sampleTimestamps.count,
            sampleOffsetUs: 0
        )
    }

    @Test
    func discardToEnd() throws {
        try writeTestData()

        // Should discard everything.
        try sampleQueue.discardToEnd()
        #expect(sampleQueue.getFirstIndex() == 8)
        #expect(sampleQueue.getReadIndex() == 8)

        // We should still be able to read the upstream format.
        try assertReadFormat(formatRequired: false, format: format2)

        // We should be able to write and read subsequent samples.
        try writeTestData()
        try assertReadTestData(startFormat: format2)
    }

    @Test
    func discardToStopAtReadPosition() throws {
        try writeTestData()

        // Shouldn't discard anything.
        try sampleQueue.discard(to: #require(sampleTimestamps.last), to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 0)

        // Read the first sample.
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 1)

        // Still shouldn't discard anything.
        try sampleQueue.discard(to: sampleTimestamps[1] - 1, to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 1)

        // Should discard the read sample.
        try sampleQueue.discard(to: sampleTimestamps[1], to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 1)
        #expect(sampleQueue.getReadIndex() == 1)

        // Still shouldn't discard anything.
        try sampleQueue.discard(to: #require(sampleTimestamps.last), to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 1)
        #expect(sampleQueue.getReadIndex() == 1)

        // Should be able to read the remaining samples.
        try assertReadTestData(startFormat: format1, firstSampleIndex: 1, sampleCount: 7)
        #expect(sampleQueue.getFirstIndex() == 1)
        #expect(sampleQueue.getReadIndex() == 8)

        // Should discard up to the second last sample.
        try sampleQueue.discard(to: #require(sampleTimestamps.last) - 1, to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 6)
        #expect(sampleQueue.getReadIndex() == 8)

        // Should discard up to the last sample.
        try sampleQueue.discard(to: #require(sampleTimestamps.last), to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 7)
        #expect(sampleQueue.getReadIndex() == 8)
    }

    @Test
    func discardToWithDuplicateTimestampsDiscardsOnlyToFirstMatch() throws {
        try writeTestData(
            data: data,
            sampleSizes: sampleSizes,
            sampleOffsets: sampleOffsets,
            sampleTimestamps: [Int64(0), 1000, 1000, 1000, 2000, 2000, 2000, 2000],
            sampleFormats: sampleFormats,
            sampleFlags: [
                .keyframe,
                [],
                .keyframe,
                .keyframe,
                [],
                [],
                .keyframe,
                .keyframe,
            ]
        )

        // Discard to first keyframe exactly matching 1000.
        try sampleQueue.discard(to: 1000, to: true, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 2)

        // Do nothing when trying again (same timestamp).
        try sampleQueue.discard(to: 1000, to: true, stopAtReadPosition: false)
        try sampleQueue.discard(to: 1000, to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 2)

        // Discard to first frame exactly matching 2000.
        try sampleQueue.discard(to: 2000, to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 4)

        // Do nothing when trying again (same timestamp).
        try sampleQueue.discard(to: 2000, to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 4)

        // Discard to first keyframe at same timestamp (2000).
        try sampleQueue.discard(to: 2000, to: true, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 6)
    }

    @Test
    func discardToDontStopAtReadPosition() throws {
        try writeTestData()

        // Shouldn't discard anything.
        try sampleQueue.discard(to: sampleTimestamps[1] - 1, to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 0)

        // Should discard the first sample.
        try sampleQueue.discard(to: sampleTimestamps[1], to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 1)
        #expect(sampleQueue.getReadIndex() == 1)

        // Should be able to read the remaining samples.
        try assertReadTestData(startFormat: format1, firstSampleIndex: 1, sampleCount: 7)
    }

    @Test
    func discardUpstreamFrom() throws {
        try writeTestData()
        try sampleQueue.discardUpstreamFrom(time: 8000)
        try sampleQueue.discardUpstreamFrom(time: 7000)
        try sampleQueue.discardUpstreamFrom(time: 6000)
        try sampleQueue.discardUpstreamFrom(time: 5000)
        try sampleQueue.discardUpstreamFrom(time: 4000)
        try sampleQueue.discardUpstreamFrom(time: 3000)
        try sampleQueue.discardUpstreamFrom(time: 2000)
        try sampleQueue.discardUpstreamFrom(time: 1000)
        try sampleQueue.discardUpstreamFrom(time: 0)

        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamFromMulti() throws {
        try writeTestData()
        try sampleQueue.discardUpstreamFrom(time: 4000)
        try sampleQueue.discardUpstreamFrom(time: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamFromNonSampleTimestamps() throws {
        try writeTestData()
        try sampleQueue.discardUpstreamFrom(time: 3500)
        try sampleQueue.discardUpstreamFrom(time: 500)
        try sampleQueue.discardUpstreamFrom(time: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamFromBeforeRead() throws {
        try writeTestData()
        try sampleQueue.discardUpstreamFrom(time: 4000)
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 4)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamFromAfterRead() throws {
        try writeTestData()
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 3)
        try sampleQueue.discardUpstreamFrom(time: 8000)
        try sampleQueue.discardToRead()
        try sampleQueue.discardUpstreamFrom(time: 7000)
        try sampleQueue.discardUpstreamFrom(time: 6000)
        try sampleQueue.discardUpstreamFrom(time: 5000)
        try sampleQueue.discardUpstreamFrom(time: 4000)
        try sampleQueue.discardUpstreamFrom(time: 3000)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func largestQueuedTimestampWithDiscardUpstreamFrom() throws {
        try writeTestData()
        let lastTimestamp = try #require(sampleTimestamps.last)
        #expect(sampleQueue.getLargestQueuedTimestamp() == lastTimestamp)
        try sampleQueue.discardUpstreamFrom(time: sampleTimestamps[sampleTimestamps.count - 1])
        // Discarding from upstream should reduce the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == sampleTimestamps[sampleTimestamps.count - 2])
        try sampleQueue.discardUpstreamFrom(time: 0)
        // Discarding everything from upstream without reading should unset the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == Int64.min)
    }

    @Test
    func largestQueuedTimestampWithDiscardUpstreamFromDecodeOrder() throws {
        let decodeOrderTimestamps: [Int64] = [0, 3000, 2000, 1000, 4000, 7000, 6000, 5000]
        try writeTestData(
            data: data,
            sampleSizes: sampleSizes,
            sampleOffsets: sampleOffsets,
            sampleTimestamps: decodeOrderTimestamps,
            sampleFormats: sampleFormats,
            sampleFlags: sampleFlags
        )
        #expect(sampleQueue.getLargestQueuedTimestamp() == 7000)
        try sampleQueue.discardUpstreamFrom(time: sampleTimestamps[sampleTimestamps.count - 2])
        // Discarding the last two samples should not change the largest timestamp, due to the decode
        // ordering of the timestamps.
        #expect(sampleQueue.getLargestQueuedTimestamp() == 7000)
        try sampleQueue.discardUpstreamFrom(time: sampleTimestamps[sampleTimestamps.count - 3])
        // Once a third sample is discarded, the largest timestamp should have changed.
        #expect(sampleQueue.getLargestQueuedTimestamp() == 4000)
        try sampleQueue.discardUpstreamFrom(time: 0)
        // Discarding everything from upstream without reading should unset the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == Int64.min)
    }

    @Test
    func discardUpstream() throws {
        try writeTestData()
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 8)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 7)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 6)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 5)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 4)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 3)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 2)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 1)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamMulti() throws {
        try writeTestData()
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 4)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamBeforeRead() throws {
        try writeTestData()
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 4)
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 4)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamAfterRead() throws {
        try writeTestData()
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 3)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 8)
        try sampleQueue.discardToRead()
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 7)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 6)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 5)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 4)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 3)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func largestQueuedTimestampWithDiscardUpstream() throws {
        try writeTestData()
        let lastTimestamp = try #require(sampleTimestamps.last)
        #expect(sampleQueue.getLargestQueuedTimestamp() == lastTimestamp)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: sampleTimestamps.count - 1)
        // Discarding from upstream should reduce the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == sampleTimestamps[sampleTimestamps.count - 2])
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 0)
        // Discarding everything from upstream without reading should unset the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == Int64.min)
    }

    @Test
    func largestQueuedTimestampWithDiscardUpstreamDecodeOrder() throws {
        let decodeOrderTimestamps: [Int64] = [0, 3000, 2000, 1000, 4000, 7000, 6000, 5000]
        try writeTestData(
            data: data,
            sampleSizes: sampleSizes,
            sampleOffsets: sampleOffsets,
            sampleTimestamps: decodeOrderTimestamps,
            sampleFormats: sampleFormats,
            sampleFlags: sampleFlags
        )
        #expect(sampleQueue.getLargestQueuedTimestamp() == 7000)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: sampleTimestamps.count - 2)
        // Discarding the last two samples should not change the largest timestamp, due to the decode
        // ordering of the timestamps.
        #expect(sampleQueue.getLargestQueuedTimestamp() == 7000)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: sampleTimestamps.count - 3)
        // Once a third sample is discarded, the largest timestamp should have changed.
        #expect(sampleQueue.getLargestQueuedTimestamp() == 4000)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 0)
        // Discarding everything from upstream without reading should unset the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == Int64.min)
    }

    @Test
    func largestQueuedTimestampWithRead() throws {
        try writeTestData()
        #expect(try sampleQueue.getLargestQueuedTimestamp() == #require(sampleTimestamps.last))
        try assertReadTestData()
        // Reading everything should not reduce the largest timestamp.
        #expect(try sampleQueue.getLargestQueuedTimestamp() == #require(sampleTimestamps.last))
    }

    @Test
    func largestReadTimestampWithReadAll() throws {
        try writeTestData()
        #expect(sampleQueue.getLargestReadTimestamp() == Int64.min)
        try assertReadTestData()
        #expect(try sampleQueue.getLargestReadTimestamp() == #require(sampleTimestamps.last))
    }

    @Test
    func largestReadTimestampWithReads() throws {
        try writeTestData()
        #expect(sampleQueue.getLargestReadTimestamp() == Int64.min)

        try assertReadTestData(firstSampleIndex: 0, sampleCount: 2)
        #expect(sampleQueue.getLargestReadTimestamp() == sampleTimestamps[1])

        try assertReadTestData(startFormat: sampleFormats[1], firstSampleIndex: 2, sampleCount: 3)
        #expect(sampleQueue.getLargestReadTimestamp() == sampleTimestamps[4])
    }

    @Test
    func largestReadTimestampWithDiscard() throws {
        // Discarding shouldn't change the read timestamp.
        try writeTestData()
        #expect(sampleQueue.getLargestReadTimestamp() == Int64.min)
        try sampleQueue.discardUpstreamSamples(discardFromIndex: 5)
        #expect(sampleQueue.getLargestReadTimestamp() == Int64.min)

        try assertReadTestData(firstSampleIndex: 0, sampleCount: 3)
        #expect(sampleQueue.getLargestReadTimestamp() == sampleTimestamps[2])

        try sampleQueue.discardUpstreamSamples(discardFromIndex: 3)
        #expect(sampleQueue.getLargestReadTimestamp() == sampleTimestamps[2])
        try sampleQueue.discardToRead()
        #expect(sampleQueue.getLargestReadTimestamp() == sampleTimestamps[2])
    }

    @Test
    func setSampleOffsetBeforeData() throws {
        let sampleOffsetUs: Int64 = 1000
        sampleQueue.setSampleOffsetTime(sampleOffsetUs)
        try writeTestData()
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 8, sampleOffsetUs: sampleOffsetUs)
        try assertReadEndOfStream(formatRequired: false)
    }

    @Test
    func setSampleOffsetBetweenSamples() throws {
        try writeTestData()
        let sampleOffsetUs: Int64 = 1000
        sampleQueue.setSampleOffsetTime(sampleOffsetUs)

        // Write a final sample now the offset is set.
        let unadjustedTimestampUs: Int64 = try #require(sampleTimestamps.last) + 1234
        try writeSample(data: data, timestampUs: unadjustedTimestampUs, flags: [])

        try assertReadTestData()
        // We expect to read the format adjusted to account for the sample offset, followed by the final
        // sample and then the end of stream.
        try assertReadFormat(
            formatRequired: false,
            format: #require(adjustFormat(format: format2, sampleOffsetUs: sampleOffsetUs))
        )
        try assertReadSample(
            timeUs: unadjustedTimestampUs + sampleOffsetUs,
            isKeyFrame: false,
            sampleData: data,
            offset: 0,
            length: data.count
        )
        try assertReadEndOfStream(formatRequired: false)
    }

    @Test
    func adjustUpstreamFormat() throws {
        let label = "label"
        sampleQueue = try MockSampleQueue(
            label: .usual(label: label),
            queue: playerSyncQueue
        )

        sampleQueue.setFormat(format1)
        try assertReadFormat(
            formatRequired: false,
            format: Self.copyWithLabel(format: format1, label: label)
        )
        try assertReadEndOfStream(formatRequired: false)
    }

    @Test
    func invalidateUpstreamFormatAdjustment() throws {
        let label = AtomicReference<String>("label1")
        sampleQueue = try MockSampleQueue(
            label: .protected(protected: label),
            queue: playerSyncQueue
        )

        sampleQueue.setFormat(format1)
        try writeSample(data: data, timestampUs: 0, flags: .keyframe)

        // Make a change that'll affect the SampleQueue's format adjustment, and invalidate it.
        label.value = "label2"
        sampleQueue.invalidateUpstreamFormatAdjustment()

        try writeSample(data: data, timestampUs: 1, flags: .keyframe)

        try assertReadFormat(
            formatRequired: false,
            format: Self.copyWithLabel(format: format1, label: "label1")
        )
        try assertReadSample(timeUs: 0, isKeyFrame: true, sampleData: data, offset: 0, length: data.count)
        try assertReadFormat(
            formatRequired: false,
            format: Self.copyWithLabel(format: format1, label: "label2")
        )
        try assertReadSample(timeUs: 1, isKeyFrame: true, sampleData: data, offset: 0, length: data.count)
        try assertReadEndOfStream(formatRequired: false)
    }

    @Test
    func splice() throws {
        try writeTestData()
        sampleQueue.splice()
        // Splice should succeed, replacing the last 4 samples with the sample being written.
        let spliceSampleTimeUs: Int64 = sampleTimestamps[4]
        sampleQueue.setFormat(formatSpliced)
        try writeSample(data: data, timestampUs: spliceSampleTimeUs, flags: [.keyframe])
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 4)
        try assertReadFormat(formatRequired: false, format: formatSpliced)
        try assertReadSample(
            timeUs: spliceSampleTimeUs,
            isKeyFrame: true,
            sampleData: data,
            offset: 0,
            length: data.count
        )
        try assertReadEndOfStream(formatRequired: false)
    }

    @Test
    func spliceAfterRead() throws {
        try writeTestData()
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 4)
        sampleQueue.splice()
        // Splice should fail, leaving the last 4 samples unchanged.
        var spliceSampleTimeUs: Int64 = sampleTimestamps[3]
        sampleQueue.setFormat(formatSpliced)
        try writeSample(data: data, timestampUs: spliceSampleTimeUs, flags: [.keyframe])
        try assertReadTestData(startFormat: sampleFormats[3], firstSampleIndex: 4, sampleCount: 4)
        try assertReadEndOfStream(formatRequired: false)

        sampleQueue.seek(to: 0, allowTimeBeyondBuffer: false)
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 4)
        sampleQueue.splice()
        // Splice should succeed, replacing the last 4 samples with the sample being written
        spliceSampleTimeUs = sampleTimestamps[3] + 1
        sampleQueue.setFormat(formatSpliced)
        try writeSample(data: data, timestampUs: spliceSampleTimeUs, flags: [.keyframe])
        try assertReadFormat(formatRequired: false, format: formatSpliced)
        try assertReadSample(
            timeUs: spliceSampleTimeUs,
            isKeyFrame: true,
            sampleData: data,
            offset: 0,
            length: data.count
        )
        try assertReadEndOfStream(formatRequired: false)
    }

    @Test
    func spliceWithSampleOffset() throws {
        let sampleOffsetUs: Int64 = 30000
        sampleQueue.setSampleOffsetTime(sampleOffsetUs)
        try writeTestData()
        sampleQueue.splice()
        // Splice should succeed, replacing the last 4 samples with the sample being written.
        let spliceSampleTimeUs: Int64 = sampleTimestamps[4]
        sampleQueue.setFormat(formatSpliced)
        try writeSample(data: data, timestampUs: spliceSampleTimeUs, flags: [.keyframe])
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 4, sampleOffsetUs: sampleOffsetUs)
        try assertReadFormat(
            formatRequired: false,
            format: #require(adjustFormat(format: formatSpliced, sampleOffsetUs: sampleOffsetUs))
        )
        try assertReadSample(
            timeUs: spliceSampleTimeUs + sampleOffsetUs,
            isKeyFrame: true,
            sampleData: data,
            offset: 0,
            length: data.count
        )
        try assertReadEndOfStream(formatRequired: false)
    }

    private func writeTestData() throws {
        try writeTestData(
            data: data,
            sampleSizes: sampleSizes,
            sampleOffsets: sampleOffsets,
            sampleTimestamps: sampleTimestamps,
            sampleFormats: sampleFormats,
            sampleFlags: sampleFlags
        )
    }

    private func writeSyncSamplesOnlyTestData() throws {
        try writeTestData(
            data: data,
            sampleSizes: sampleSizes,
            sampleOffsets: sampleOffsets,
            sampleTimestamps: sampleTimestamps,
            sampleFormats: sampleFormatsSyncSamplesOnly,
            sampleFlags: sampleFlagsSyncSamplesOnly
        )
    }

    private func writeTestData(
        data: [UInt8],
        sampleSizes: [Int],
        sampleOffsets: [Int],
        sampleTimestamps: [Int64],
        sampleFormats: [AnyFormat],
        sampleFlags: [SampleProperties.Flags]
    ) throws {
        try sampleQueue.sampleData(data: data, length: data.count, isolation: TestableSyncPlayerActor.shared)
        var format: AnyFormat?

        for index in 0 ..< sampleTimestamps.count {
            if sampleFormats[index] != format {
                sampleQueue.setFormat(sampleFormats[index])
                format = sampleFormats[index]
            }

            try sampleQueue.sampleMetadata(
                time: sampleTimestamps[index],
                flags: sampleFlags[index],
                size: sampleSizes[index],
                offset: sampleOffsets[index]
            )
        }
    }

    private func writeSample(data: [UInt8], timestampUs: Int64, flags: SampleProperties.Flags) throws {
        try sampleQueue.sampleData(data: data, length: data.count, isolation: TestableSyncPlayerActor.shared)
        try sampleQueue.sampleMetadata(time: timestampUs, flags: flags, size: data.count, offset: 0)
    }

    private func writeAndDiscardPlaceholderSamples(sampleCount: Int) throws {
        sampleQueue.setFormat(formatSyncSampleOnly1)
        for _ in 0 ..< sampleCount {
            try writeSample(data: [], timestampUs: 0, flags: .keyframe)
        }
        try sampleQueue.discardToEnd()
    }

    private func assertReadSyncSampleOnlyTestData(
        firstSampleIndex: Int = 0,
        sampleCount: Int? = nil
    ) throws {
        let sampleCount = sampleCount ?? sampleTimestamps.count
        try assertReadTestData(
            firstSampleIndex: firstSampleIndex,
            sampleCount: sampleCount,
            sampleFormats: sampleFormatsSyncSamplesOnly,
            sampleFlags: sampleFlagsSyncSamplesOnly
        )
    }

    private func assertReadTestData(
        startFormat: AnyFormat? = nil,
        firstSampleIndex: Int = 0,
        sampleCount: Int? = nil,
        sampleOffsetUs: Int64 = 0,
        sampleFormats: [AnyFormat]? = nil,
        sampleFlags: [SampleProperties.Flags]? = nil
    ) throws {
        let sampleCount = sampleCount ?? sampleTimestamps.count - firstSampleIndex
        let sampleFormats = sampleFormats ?? self.sampleFormats
        let sampleFlags = sampleFlags ?? self.sampleFlags

        var format = adjustFormat(format: startFormat, sampleOffsetUs: sampleOffsetUs)
        for i in firstSampleIndex ..< (firstSampleIndex + sampleCount) {
            if i == 4 {
                print()
            }
            let testSampleFormat = try #require(adjustFormat(format: sampleFormats[i], sampleOffsetUs: sampleOffsetUs))
            if testSampleFormat != format {
                // If the format has changed, we should read it.
                try assertReadFormat(formatRequired: false, format: testSampleFormat)
                format = testSampleFormat
            }

            // If we require the format, we should always read it.
            try assertReadFormat(formatRequired: true, format: testSampleFormat)
            // Assert the sample is as expected.
            let expectedTimeUs = sampleTimestamps[i] + sampleOffsetUs
            try assertReadSample(
                timeUs: expectedTimeUs,
                isKeyFrame: sampleFlags[i].contains(.keyframe),
                sampleData: data,
                offset: data.count - sampleOffsets[i] - sampleSizes[i],
                length: sampleSizes[i]
            )
        }
    }

    private func assertNoSamplesToRead(endFormat: AnyFormat?) throws {
        // If not formatRequired or loadingFinished, should read nothing.
        try assertReadNothing(formatRequired: false)

        // If formatRequired, should read the end format if set, else read nothing.
        if let endFormat {
            try assertReadFormat(formatRequired: true, format: endFormat)
        } else {
            try assertReadNothing(formatRequired: true)
        }

        // If loadingFinished, should read end of stream.
        try assertReadEndOfStream(formatRequired: false)
        try assertReadEndOfStream(formatRequired: true)

        // Having read end of stream should not affect other cases.
        try assertReadNothing(formatRequired: false)
        if let endFormat {
            try assertReadFormat(formatRequired: true, format: endFormat)
        } else {
            try assertReadNothing(formatRequired: true)
        }
    }

    private func assertReadNothing(formatRequired: Bool) throws {
        clearInputBuffer()
        let result = try sampleQueue.read(
            buffer: inputBuffer,
            readFlags: formatRequired ? .requireFormat : [],
            loadingFinished: false
        )
        #expect(result == .nothingRead)
        assertInputBufferContainsNoSampleData()
        assertInputBufferHasNoDefaultFlagsSet()
    }

    private func assertReadEndOfStream(formatRequired: Bool) throws {
        clearInputBuffer()
        let result = try sampleQueue.read(
            buffer: inputBuffer,
            readFlags: formatRequired ? .requireFormat : [],
            loadingFinished: true
        )
        #expect(result == .didReadBuffer)
        assertInputBufferContainsNoSampleData()
        #expect(inputBuffer.flags.contains(.endOfStream))
    }

    private func assertReadFormat(formatRequired: Bool, format: AnyFormat) throws {
        clearInputBuffer()
        let result = try sampleQueue.read(
            buffer: inputBuffer,
            readFlags: formatRequired ? .requireFormat : [],
            loadingFinished: false
        )

        if result == .didReadBuffer || result == .nothingRead {
            print()
        }
        if case let .didReadFormat(readedFormat) = result,
           readedFormat != format {
            print()
        }
        // formatHolder should be populated.
        #expect({
            if case let .didReadFormat(readedFormat) = result {
                readedFormat == format
            } else {
                false
            }
        }())

        // inputBuffer should not be populated.
        assertInputBufferContainsNoSampleData()
        assertInputBufferHasNoDefaultFlagsSet()
    }

    private func assertReadSample(
        timeUs: Int64,
        isKeyFrame: Bool,
        sampleData: [UInt8],
        offset: Int,
        length: Int
    ) throws {
        // Check that peek whilst omitting data yields the expected values.
        let flagsOnlyBuffer = TestInputBuffer()
        var result = try sampleQueue.read(
            buffer: flagsOnlyBuffer,
            readFlags: [.omitSampleData, .peek],
            loadingFinished: false
        )
        assertSampleBufferReadResult(inputBuffer: flagsOnlyBuffer, result: result, timeUs: timeUs, isKeyFrame: isKeyFrame, isLastSample: false)

        // Check that peek yields the expected values.
        clearInputBuffer()
        result = try sampleQueue.read(
            buffer: inputBuffer,
            readFlags: [.peek],
            loadingFinished: false
        )
        try assertSampleBufferReadResult(result: result, timeUs: timeUs, isKeyFrame: isKeyFrame, isLastSample: false, sampleData: sampleData, offset: offset, length: length)

        // Check that read yields the expected values.
        clearInputBuffer()
        result = try sampleQueue.read(
            buffer: inputBuffer,
            readFlags: [],
            loadingFinished: false
        )
        try assertSampleBufferReadResult(result: result, timeUs: timeUs, isKeyFrame: isKeyFrame, isLastSample: false, sampleData: sampleData, offset: offset, length: length)
    }

    private func assertReadLastSample(
        timeUs: Int64,
        isKeyFrame: Bool,
        sampleData: [UInt8],
        offset: Int,
        length: Int
    ) throws {
        // Check that peek whilst omitting data yields the expected values.
        let flagsOnlyBuffer = TestInputBuffer()
        var result = try sampleQueue.read(
            buffer: flagsOnlyBuffer,
            readFlags: [.omitSampleData, .peek],
            loadingFinished: true
        )
        assertSampleBufferReadResult(inputBuffer: flagsOnlyBuffer, result: result, timeUs: timeUs, isKeyFrame: isKeyFrame, isLastSample: true)

        // Check that peek yields the expected values.
        clearInputBuffer()
        result = try sampleQueue.read(buffer: inputBuffer, readFlags: .peek, loadingFinished: true)
        try assertSampleBufferReadResult(result: result, timeUs: timeUs, isKeyFrame: isKeyFrame, isLastSample: true, sampleData: sampleData, offset: offset, length: length)

        // Check that read yields the expected values.
        clearInputBuffer()
        result = try sampleQueue.read(buffer: inputBuffer, readFlags: [], loadingFinished: true)
        try assertSampleBufferReadResult(result: result, timeUs: timeUs, isKeyFrame: isKeyFrame, isLastSample: true, sampleData: sampleData, offset: offset, length: length)
    }

    private func assertSampleBufferReadResult(
        inputBuffer: TestInputBuffer,
        result: TestReadResult,
        timeUs: Int64,
        isKeyFrame: Bool,
        isLastSample: Bool
    ) {
        #expect(result == .didReadBuffer)
        #expect(inputBuffer.timeUs == timeUs)
        #expect(inputBuffer.flags.contains(.keyframe) == isKeyFrame)
        #expect(inputBuffer.flags.contains(.lastSample) == isLastSample)
    }

    private func assertSampleBufferReadResult(
        result: TestReadResult,
        timeUs: Int64,
        isKeyFrame: Bool,
        isLastSample: Bool,
        sampleData: [UInt8],
        offset: Int,
        length: Int
    ) throws {
        assertSampleBufferReadResult(inputBuffer: inputBuffer, result: result, timeUs: timeUs, isKeyFrame: isKeyFrame, isLastSample: isLastSample)
        #expect(inputBuffer.size == length)
        let buffer = try inputBuffer.dequeue()

        let range = offset ..< (offset + length)
        for (index, byte) in sampleData[range].enumerated() {
            #expect(buffer[index] == byte)
        }
    }

    private func assertInputBufferContainsNoSampleData() {
        guard (try? inputBuffer.dequeue()) != nil else {
            return
        }

        #expect(inputBuffer.size == 0)
    }

    private func assertInputBufferHasNoDefaultFlagsSet() {
        #expect(!inputBuffer.flags.contains(.endOfStream))
    }

    func clearInputBuffer() {
        inputBuffer.clear()
    }

    private func adjustFormat(format: AnyFormat?, sampleOffsetUs: Int64) -> AnyFormat? {
        guard var format, sampleOffsetUs != 0 else { return format }
        let subsampleOffset = (format.text?.subsampleOffset ?? 0) + Double(sampleOffsetUs) / 1_000_000
        format.text?.subsampleOffset = subsampleOffset
        return format
    }

    /// Cues timed from the start of the track, whose times move with the offset of the samples.
    private func buildFormat(id: String) -> AnyFormat {
        AnyFormat(TextFormat {
            $0.id = id
            $0.codec = TextCodec(.applicationSEPlayerCues)
            $0.subsampleOffset = 0
        })
    }

    private static func linearPCMFormat(id: String) -> AnyFormat {
        AnyFormat(AudioFormat {
            $0.id = id
            $0.codec = .pcm { $0.bitDepth = 16 }
            $0.sampleRate = 44100
            $0.channelCount = 1
        })
    }

    nonisolated static func copyWithLabel(format: AnyFormat, label: String) -> AnyFormat {
        format.with { $0.label = label }
    }
}

private final class MockSampleQueue: SampleQueue {
    enum LabelVariant {
        case usual(label: String)
        case protected(protected: AtomicReference<String>)
    }

    let label: LabelVariant

    init(label: LabelVariant, queue: Queue) throws {
        self.label = label

        try super.init(queue: queue)
    }

    override func getAdjustedUpstreamFormat(_ format: AnyFormat) -> AnyFormat {
        let label: String = switch label {
        case let .usual(label):
            label
        case let .protected(protected):
            protected.value
        }

        return super.getAdjustedUpstreamFormat(
            SampleQueueTest.copyWithLabel(format: format, label: label)
        )
    }
}

private final class AtomicReference<Value> {
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    private var _value: Value
    private let lock: UnfairLock

    init(_ value: Value) {
        self._value = value
        lock = UnfairLock()
    }
}

// MARK: - The tests' view of the queue

/// What a read hands out, without the sample buffer itself.
enum TestReadResult: Equatable {
    case nothingRead
    case didReadFormat(AnyFormat)
    case didReadBuffer
}

/// Receives what a read hands out: the time, the flags and, unless omitted, the data.
final class TestInputBuffer {
    private(set) var timeUs: Int64 = 0
    private(set) var flags: SampleProperties.Flags = []
    private var data: [UInt8]?

    var size: Int { data?.count ?? 0 }

    func clear() {
        timeUs = 0
        flags = []
        data = nil
    }

    struct NoDataError: Error {}

    func dequeue() throws -> [UInt8] {
        guard let data else { throw NoDataError() }
        return data
    }

    fileprivate func fill(from sampleBuffer: CMSampleBuffer) throws {
        timeUs = sampleBuffer.presentationTimeStamp.isNumeric ? sampleBuffer.presentationTimeStamp.microseconds : 0
        flags = sampleBuffer.flags
        if let dataBuffer = sampleBuffer.dataBuffer {
            var bytes = [UInt8](repeating: 0, count: dataBuffer.dataLength)
            try bytes.withUnsafeMutableBytes { try dataBuffer.copyDataBytes(to: $0) }
            data = bytes
        }
    }
}

/// The queue in the units of the tests: microseconds, with `Int64.min` and `Int64.max` for
/// negative and positive infinity, and sample data written from the start of a byte buffer.
extension SampleQueue {
    private func onQueue<T>(_ body: (isolated PlayerActor) throws -> T) rethrows -> T {
        try playerSyncQueue.playerActor().assumeIsolated(body)
    }

    private static func time(_ us: Int64) -> CMTime {
        switch us {
        case .max: .positiveInfinity
        case .min: .negativeInfinity
        default: .from(microseconds: us)
        }
    }

    private static func us(_ time: CMTime) -> Int64 {
        if time == .positiveInfinity { return .max }
        if time == .negativeInfinity || !time.isNumeric { return .min }
        return time.microseconds
    }

    func sampleData(data: [UInt8], length: Int, isolation: TestableSyncPlayerActor) throws {
        let bytes = Array(data.prefix(length))
        // Writing nothing writes nothing; a block buffer can't be empty.
        guard !bytes.isEmpty else { return }
        let blockBuffer = try CMBlockBuffer(length: bytes.count, flags: .assureMemoryNow)
        try bytes.withUnsafeBytes { try blockBuffer.replaceDataBytes(with: $0) }
        onQueue { _ in sampleData(data: blockBuffer) }
    }

    func sampleMetadata(time: Int64, flags: SampleProperties.Flags, size: Int, offset: Int) throws {
        let time = Self.time(time)
        try onQueue { _ in
            try sampleMetadata(
                SampleProperties(
                    timingInfo: CMSampleTimingInfo(
                        duration: .invalid,
                        presentationTimeStamp: time,
                        decodeTimeStamp: time
                    ),
                    dataRange: offset ..< (offset + size),
                    flags: flags
                )
            )
        }
    }

    func read(buffer: TestInputBuffer, readFlags: ReadFlags, loadingFinished: Bool) throws -> TestReadResult {
        switch try read(readFlags: readFlags, loadingFinished: loadingFinished) {
        case .nothingRead:
            return .nothingRead
        case let .didReadFormat(format):
            return .didReadFormat(format)
        case let .didReadBuffer(sampleBuffer):
            try buffer.fill(from: sampleBuffer)
            return .didReadBuffer
        }
    }

    @discardableResult
    func seek(to timeUs: Int64, allowTimeBeyondBuffer: Bool) -> Bool {
        seek(time: Self.time(timeUs), allowTimeBeyondBuffer: allowTimeBeyondBuffer)
    }

    func getSkipCount(time: Int64, allowEndOfQueue: Bool) -> Int {
        getSkipCount(time: Self.time(time), allowEndOfQueue: allowEndOfQueue)
    }

    func discard(to timeUs: Int64, to keyframe: Bool, stopAtReadPosition: Bool) throws {
        try discard(toTime: Self.time(timeUs), to: keyframe, stopAtReadPosition: stopAtReadPosition)
    }

    func discardUpstreamFrom(time: Int64) throws {
        try discardUpstreamFrom(time: Self.time(time))
    }

    func getLargestQueuedTimestamp() -> Int64 {
        Self.us(getLargestQueuedTimestamp())
    }

    func getLargestReadTimestamp() -> Int64 {
        Self.us(getLargestReadTimestamp())
    }

    func setStartTime(_ timeUs: Int64) {
        setStartTime(Self.time(timeUs))
    }

    func setSampleOffsetTime(_ sampleOffsetUs: Int64) {
        setSampleOffsetTime(Self.time(sampleOffsetUs))
    }
}
