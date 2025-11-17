//
//  SampleQueueTest.swift
//  SEPlayer Tests
//
//  Created by Damir Yackupov on 03.11.2025.
//

import Testing
@testable import SEPlayer

@TestableSyncPlayerActor
class SampleQueueTest {
    private let allocationSize: Int = 16
    private lazy var format1 = buildFormat(id: "1")
    private lazy var format2 = buildFormat(id: "2")
    private lazy var format1Copy = buildFormat(id: "1")
    private lazy var formatSpliced = buildFormat(id: "spliced")
    private let formatSyncSampleOnly1 = Format.Builder().setId("sync1").setSampleMimeType(.audioRAW).build()
    private let formatSyncSampleOnly2 = Format.Builder().setId("sync2").setSampleMimeType(.audioRAW).build()

    private lazy var dataCapacity = allocationSize * 10
    private lazy var data = TestUtil.buildTestData(lenght: dataCapacity)

    private lazy var sampleSizes: [Int] = [
        allocationSize - 1,
        allocationSize - 2,
        allocationSize - 1,
        allocationSize - 1,
        allocationSize,
        allocationSize * 2,
        allocationSize * 2 - 2,
        allocationSize
    ]
    
    private lazy var sampleOffsets: [Int] = [
        allocationSize * 9,
        allocationSize * 8 + 1,
        allocationSize * 7,
        allocationSize * 6 + 1,
        allocationSize * 5,
        allocationSize * 3,
        allocationSize + 1,
        0
    ]
    
    private let sampleTimestamps: [Int64] = [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000]
    private let sampleFlags: [SampleFlags] = [.keyframe, [], [], [], .keyframe, [], [], []]
    private lazy var sampleFlagsSyncSamplesOnly = Array<SampleFlags>(repeating: .keyframe, count: sampleFlags.count)
    private lazy var sampleFormats: [Format] = [format1, format1, format1, format1, format2, format2, format2, format2]
    private let dataSecondKeyframeIndex = 4
    private lazy var sampleFormatsSyncSamplesOnly: [Format] = [
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

    private let allocator: Allocator
    private var sampleQueue: SampleQueue
    private let inputBuffer: DecoderInputBuffer

    init() {
        allocator = DefaultAllocator(trimOnReset: false, individualAllocationSize: allocationSize)
        sampleQueue = SampleQueue(queue: playerSyncQueue, allocator: allocator)
        inputBuffer = DecoderInputBuffer()
        inputBuffer.enqueue(buffer: UnsafeMutableRawBufferPointer(
            UnsafeMutableBufferPointer<UInt8>.allocate(capacity: dataCapacity)
        ))
    }

    @Test
    func capacityIncreases() throws {
        let numberOfSamplesToInput = 3 * SampleQueue.sampleCapacityIncrement + 1
        sampleQueue.setFormat(format1)
        try sampleQueue.sampleData(data: ByteBuffer(repeating: 0, count: numberOfSamplesToInput), length: numberOfSamplesToInput)
        
        for i in 0..<numberOfSamplesToInput {
            sampleQueue.sampleMetadata(
                time: Int64(i * 1000),
                flags: .keyframe,
                size: 1,
                offset: numberOfSamplesToInput - i - 1
            )
        }
        try assertReadFormat(formatRequired: false, format: format1)
        
        for i in 0..<numberOfSamplesToInput {
            try assertReadSample(
                timeUs: Int64(i * 1000),
                isKeyFrame: true,
                sampleData: ByteBuffer(repeating: 0, count: 1),
                offset: 0,
                length: 1
            )
        }
        
        try assertReadNothing(formatRequired: false)
    }
    
    @Test
    func resetReleasesAllocations() throws {
        try writeTestData()
        assertAllocationCount(count: 10)
        sampleQueue.reset()
        assertAllocationCount(count: 0)
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
                return readedFormat == format1
            } else {
                return false
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
        try sampleQueue.sampleData(data: data, length: allocationSize)
        sampleQueue.sampleMetadata(time: 0, flags: .keyframe, size: allocationSize, offset: 0)
        // Writing multiple formats should not cause a format change on the read side, provided the last
        // format to be written is equal to the format of the previous sample.
        sampleQueue.setFormat(format2)
        sampleQueue.setFormat(format1Copy)
        try sampleQueue.sampleData(data: data, length: allocationSize)
        sampleQueue.sampleMetadata(time: 1000, flags: .keyframe, size: allocationSize, offset: 0)
        
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
        try sampleQueue.sampleData(data: data, length: allocationSize)
        sampleQueue.sampleMetadata(time: 2000, flags: .keyframe, size: allocationSize, offset: 0)
        
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
        try sampleQueue.sampleData(data: data, length: allocationSize)
        assertAllocationCount(count: 1)
        
        // Nothing to read without sample metadata
        try assertNoSamplesToRead(endFormat: nil)
        
        sampleQueue.setFormat(format1)
        
        // Read the format.
        try assertReadFormat(formatRequired: false, format: format1)
        // Nothing to read without sample metadata
        try assertNoSamplesToRead(endFormat: format1)
        
        sampleQueue.sampleMetadata(time: 1000, flags: .keyframe, size: allocationSize, offset: 0)
        
        // If formatRequired, should read the format rather than the sample.
        try assertReadFormat(formatRequired: true, format: format1)
        // Otherwise should read the sample.
        try assertReadSample(timeUs: 1000, isKeyFrame: true, sampleData: data, offset: 0, length: allocationSize)
        // Allocation should still be held.
        assertAllocationCount(count: 1)
        sampleQueue.discardToRead()
        // The allocation should have been released.
        assertAllocationCount(count: 0)
        
        // Nothing to read.
        try assertNoSamplesToRead(endFormat: format1)
        
        // Write a second sample followed by one byte that does not belong to it.
        try sampleQueue.sampleData(data: data, length: allocationSize)
        sampleQueue.sampleMetadata(time: 2000, flags: [], size: allocationSize - 1, offset: 1)
        
        // If formatRequired, should read the format rather than the sample.
        try assertReadFormat(formatRequired: true, format: format1)
        // Try reading the sample
        try assertReadSample(timeUs: 2000, isKeyFrame: false, sampleData: data, offset: 0, length: allocationSize - 1)
        // Allocation should still be held.
        assertAllocationCount(count: 1)
        sampleQueue.discardToRead()
        // The last byte written to the sample queue may belong to a sample whose metadata has yet to be
        // written, so an allocation should still be held.
        assertAllocationCount(count: 1)
        
        // Write metadata for a third sample containing the remaining byte.
        sampleQueue.sampleMetadata(time: 3000, flags: [], size: 1, offset: 0)
        
        // If formatRequired, should read the format rather than the sample.
        try assertReadFormat(formatRequired: true, format: format1)
        // Try reading the sample
        try assertReadSample(timeUs: 3000, isKeyFrame: false, sampleData: data, offset: allocationSize - 1, length: 1)
        // Allocation should still be held.
        assertAllocationCount(count: 1)
        sampleQueue.discardToRead()
        assertAllocationCount(count: 0)
    }
    
    @Test
    func readSingleSampleWithLoadingFinished() throws {
        try sampleQueue.sampleData(data: data, length: allocationSize)
        sampleQueue.setFormat(format1)
        sampleQueue.sampleMetadata(time: 1000, flags: .keyframe, size: allocationSize, offset: 0)
        
        assertAllocationCount(count: 1)
        // If formatRequired, should read the format rather than the sample.
        try assertReadFormat(formatRequired: true, format: format1)
        try assertReadLastSample(timeUs: 1000, isKeyFrame: true, sampleData: data, offset: 0, length: allocationSize)
        
        // Allocation should still be held.
        assertAllocationCount(count: 1)
        sampleQueue.discardToRead()
        // The allocation should have been released.
        assertAllocationCount(count: 0)
    }
    
    @Test
    func readMultiSamples() throws {
        try writeTestData()
        #expect(sampleQueue.getLargestQueuedTimestamp() == sampleTimestamps.last)
        assertAllocationCount(count: 10)
        try assertReadTestData()
        assertAllocationCount(count: 10)
        sampleQueue.discardToEnd()
        assertAllocationCount(count: 0)
    }
    
    @Test
    func readMultiSamplesTwice() throws {
        try writeTestData()
        try writeTestData()
        assertAllocationCount(count: 20)
        try assertReadTestData(startFormat: format2)
        try assertReadTestData(startFormat: format2)
        assertAllocationCount(count: 20)
        sampleQueue.discardToEnd()
        assertAllocationCount(count: 0)
    }
    
    @Test
    func readMultiWithSeek() throws {
        try writeTestData()
        try assertReadTestData()
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 8)
        assertAllocationCount(count: 10)

        sampleQueue.seek(to: 0)
        assertAllocationCount(count: 10)
        // Read again.
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 0)
        try assertReadTestData()
    }
    
    @Test
    func emptyQueueReturnsLoadingFinished() throws {
        try sampleQueue.sampleData(data: data, length: data.readableBytes)
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
        sampleQueue.discardToRead()
        #expect(sampleQueue.getFirstIndex() == 8)
        #expect(sampleQueue.getReadIndex() == 8)
        assertAllocationCount(count: 0)
        
        sampleQueue.seek(to: 0)
        assertAllocationCount(count: 0)
        // Can't read again.
        #expect(sampleQueue.getFirstIndex() == 8)
        #expect(sampleQueue.getReadIndex() == 8)
        try assertReadEndOfStream(formatRequired: false)
    }
    
    @Test
    func skipToEnd() throws {
        try writeTestData()
        sampleQueue.skip(count: sampleQueue.getSkipCount(time: .max, allowEndOfQueue: true))
        assertAllocationCount(count: 10)
        sampleQueue.discardToRead()
        assertAllocationCount(count: 0)
        // Despite skipping all samples, we should still read the last format, since this is the
        // expected format for a subsequent sample.
        try assertReadFormat(formatRequired: false, format: format2)
        // Once the format has been read, there's nothing else to read.
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func skipToEndRetainsUnassignedData() throws {
        sampleQueue.setFormat(format1)
        try sampleQueue.sampleData(data: data, length: allocationSize)
        sampleQueue.skip(count: sampleQueue.getSkipCount(time: .max, allowEndOfQueue: true))
        assertAllocationCount(count: 1)
        sampleQueue.discardToRead()
        // Skipping shouldn't discard data that may belong to a sample whose metadata has yet to be written.
        assertAllocationCount(count: 1)
        // We should be able to read the format.
        try assertReadFormat(formatRequired: false, format: format1)
        // Once the format has been read, there's nothing else to read.
        try assertNoSamplesToRead(endFormat: format1)

        sampleQueue.sampleMetadata(time: 0, flags: .keyframe, size: allocationSize, offset: 0)
        // Once the metadata has been written, check the sample can be read as expected.
        try assertReadSample(timeUs: 0, isKeyFrame: true, sampleData: data, offset: 0, length: allocationSize)
        try assertNoSamplesToRead(endFormat: format1)
        assertAllocationCount(count: 1)
        sampleQueue.discardToEnd()
        assertAllocationCount(count: 0)
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
            offset: data.readableBytes - sampleOffsets[7] - sampleSizes[7],
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
        sampleQueue.discardToEnd()
        #expect(sampleQueue.getFirstIndex() == 8)
        #expect(sampleQueue.getReadIndex() == 8)
        assertAllocationCount(count: 0)

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
        assertAllocationCount(count: 10)

        // Read the first sample.
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 1)

        // Still shouldn't discard anything.
        sampleQueue.discard(to: sampleTimestamps[1] - 1, to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 1)
        assertAllocationCount(count: 10)

        // Should discard the read sample.
        sampleQueue.discard(to: sampleTimestamps[1], to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 1)
        #expect(sampleQueue.getReadIndex() == 1)
        assertAllocationCount(count: 9)

        // Still shouldn't discard anything.
        try sampleQueue.discard(to: #require(sampleTimestamps.last), to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 1)
        #expect(sampleQueue.getReadIndex() == 1)
        assertAllocationCount(count: 9)

        // Should be able to read the remaining samples.
        try assertReadTestData(startFormat: format1, firstSampleIndex: 1, sampleCount: 7)
        #expect(sampleQueue.getFirstIndex() == 1)
        #expect(sampleQueue.getReadIndex() == 8)

        // Should discard up to the second last sample.
        try sampleQueue.discard(to: #require(sampleTimestamps.last) - 1, to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 6)
        #expect(sampleQueue.getReadIndex() == 8)
        assertAllocationCount(count: 3)

        // Should discard up to the last sample.
        try sampleQueue.discard(to: #require(sampleTimestamps.last), to: false, stopAtReadPosition: true)
        #expect(sampleQueue.getFirstIndex() == 7)
        #expect(sampleQueue.getReadIndex() == 8)
        assertAllocationCount(count: 1)
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
                .keyframe
            ]
        )

        // Discard to first keyframe exactly matching 1000.
        sampleQueue.discard(to: 1000, to: true, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 2)

        // Do nothing when trying again (same timestamp).
        sampleQueue.discard(to: 1000, to: true, stopAtReadPosition: false)
        sampleQueue.discard(to: 1000, to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 2)

        // Discard to first frame exactly matching 2000.
        sampleQueue.discard(to: 2000, to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 4)

        // Do nothing when trying again (same timestamp).
        sampleQueue.discard(to: 2000, to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 4)

        // Discard to first keyframe at same timestamp (2000).
        sampleQueue.discard(to: 2000, to: true, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 6)
    }

    @Test
    func discardToDontStopAtReadPosition() throws {
        try writeTestData()

        // Shouldn't discard anything.
        sampleQueue.discard(to: sampleTimestamps[1] - 1, to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 0)
        #expect(sampleQueue.getReadIndex() == 0)
        assertAllocationCount(count: 10)

        // Should discard the first sample.
        sampleQueue.discard(to: sampleTimestamps[1], to: false, stopAtReadPosition: false)
        #expect(sampleQueue.getFirstIndex() == 1)
        #expect(sampleQueue.getReadIndex() == 1)
        assertAllocationCount(count: 9)

        // Should be able to read the remaining samples.
        try assertReadTestData(startFormat: format1, firstSampleIndex: 1, sampleCount: 7)
    }

    @Test
    func discardUpstreamFrom() throws {
        try writeTestData()
        sampleQueue.discardUpstreamFrom(time: 8000)
        assertAllocationCount(count: 10)
        sampleQueue.discardUpstreamFrom(time: 7000)
        assertAllocationCount(count: 9)
        sampleQueue.discardUpstreamFrom(time: 6000)
        assertAllocationCount(count: 7)
        sampleQueue.discardUpstreamFrom(time: 5000)
        assertAllocationCount(count: 5)
        sampleQueue.discardUpstreamFrom(time: 4000)
        assertAllocationCount(count: 4)
        sampleQueue.discardUpstreamFrom(time: 3000)
        assertAllocationCount(count: 3)
        sampleQueue.discardUpstreamFrom(time: 2000)
        assertAllocationCount(count: 2)
        sampleQueue.discardUpstreamFrom(time: 1000)
        assertAllocationCount(count: 1)
        sampleQueue.discardUpstreamFrom(time: 0)
        assertAllocationCount(count: 0)

        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamFromMulti() throws {
        try writeTestData()
        sampleQueue.discardUpstreamFrom(time: 4000)
        assertAllocationCount(count: 4)
        sampleQueue.discardUpstreamFrom(time: 0)
        assertAllocationCount(count: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamFromNonSampleTimestamps() throws {
        try writeTestData()
        sampleQueue.discardUpstreamFrom(time: 3500)
        assertAllocationCount(count: 4)
        sampleQueue.discardUpstreamFrom(time: 500)
        assertAllocationCount(count: 1)
        sampleQueue.discardUpstreamFrom(time: 0)
        assertAllocationCount(count: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamFromBeforeRead() throws {
        try writeTestData()
        sampleQueue.discardUpstreamFrom(time: 4000)
        assertAllocationCount(count: 4)
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 4)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamFromAfterRead() throws {
        try writeTestData()
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 3)
        sampleQueue.discardUpstreamFrom(time: 8000)
        assertAllocationCount(count: 10)
        sampleQueue.discardToRead()
        assertAllocationCount(count: 7)
        sampleQueue.discardUpstreamFrom(time: 7000)
        assertAllocationCount(count: 6)
        sampleQueue.discardUpstreamFrom(time: 6000)
        assertAllocationCount(count: 4)
        sampleQueue.discardUpstreamFrom(time: 5000)
        assertAllocationCount(count: 2)
        sampleQueue.discardUpstreamFrom(time: 4000)
        assertAllocationCount(count: 1)
        sampleQueue.discardUpstreamFrom(time: 3000)
        assertAllocationCount(count: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func largestQueuedTimestampWithDiscardUpstreamFrom() throws {
        try writeTestData()
        let lastTimestamp = try #require(sampleTimestamps.last)
        #expect(sampleQueue.getLargestQueuedTimestamp() == lastTimestamp)
        sampleQueue.discardUpstreamFrom(time: sampleTimestamps[sampleTimestamps.count - 1])
        // Discarding from upstream should reduce the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == sampleTimestamps[sampleTimestamps.count - 2])
        sampleQueue.discardUpstreamFrom(time: 0)
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
        sampleQueue.discardUpstreamFrom(time: sampleTimestamps[sampleTimestamps.count - 2])
        // Discarding the last two samples should not change the largest timestamp, due to the decode
        // ordering of the timestamps.
        #expect(sampleQueue.getLargestQueuedTimestamp() == 7000)
        sampleQueue.discardUpstreamFrom(time: sampleTimestamps[sampleTimestamps.count - 3])
        // Once a third sample is discarded, the largest timestamp should have changed.
        #expect(sampleQueue.getLargestQueuedTimestamp() == 4000)
        sampleQueue.discardUpstreamFrom(time: 0)
        // Discarding everything from upstream without reading should unset the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == Int64.min)
    }

    @Test
    func discardUpstream() throws {
        try writeTestData()
        sampleQueue.discardUpstreamSamples(discardFromIndex: 8)
        assertAllocationCount(count: 10)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 7)
        assertAllocationCount(count: 9)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 6)
        assertAllocationCount(count: 7)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 5)
        assertAllocationCount(count: 5)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 4)
        assertAllocationCount(count: 4)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 3)
        assertAllocationCount(count: 3)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 2)
        assertAllocationCount(count: 2)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 1)
        assertAllocationCount(count: 1)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 0)
        assertAllocationCount(count: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamMulti() throws {
        try writeTestData()
        sampleQueue.discardUpstreamSamples(discardFromIndex: 4)
        assertAllocationCount(count: 4)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 0)
        assertAllocationCount(count: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamBeforeRead() throws {
        try writeTestData()
        sampleQueue.discardUpstreamSamples(discardFromIndex: 4)
        assertAllocationCount(count: 4)
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 4)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func discardUpstreamAfterRead() throws {
        try writeTestData()
        try assertReadTestData(firstSampleIndex: 0, sampleCount: 3)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 8)
        assertAllocationCount(count: 10)
        sampleQueue.discardToRead()
        assertAllocationCount(count: 7)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 7)
        assertAllocationCount(count: 6)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 6)
        assertAllocationCount(count: 4)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 5)
        assertAllocationCount(count: 2)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 4)
        assertAllocationCount(count: 1)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 3)
        assertAllocationCount(count: 0)
        try assertReadFormat(formatRequired: false, format: format2)
        try assertNoSamplesToRead(endFormat: format2)
    }

    @Test
    func largestQueuedTimestampWithDiscardUpstream() throws {
        try writeTestData()
        let lastTimestamp = try #require(sampleTimestamps.last)
        #expect(sampleQueue.getLargestQueuedTimestamp() == lastTimestamp)
        sampleQueue.discardUpstreamSamples(discardFromIndex: sampleTimestamps.count - 1)
        // Discarding from upstream should reduce the largest timestamp.
        #expect(sampleQueue.getLargestQueuedTimestamp() == sampleTimestamps[sampleTimestamps.count - 2])
        sampleQueue.discardUpstreamSamples(discardFromIndex: 0)
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
        sampleQueue.discardUpstreamSamples(discardFromIndex: sampleTimestamps.count - 2)
        // Discarding the last two samples should not change the largest timestamp, due to the decode
        // ordering of the timestamps.
        #expect(sampleQueue.getLargestQueuedTimestamp() == 7000)
        sampleQueue.discardUpstreamSamples(discardFromIndex: sampleTimestamps.count - 3)
        // Once a third sample is discarded, the largest timestamp should have changed.
        #expect(sampleQueue.getLargestQueuedTimestamp() == 4000)
        sampleQueue.discardUpstreamSamples(discardFromIndex: 0)
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
        sampleQueue.discardUpstreamSamples(discardFromIndex: 5)
        #expect(sampleQueue.getLargestReadTimestamp() == Int64.min)

        try assertReadTestData(firstSampleIndex: 0, sampleCount: 3)
        #expect(sampleQueue.getLargestReadTimestamp() == sampleTimestamps[2])

        sampleQueue.discardUpstreamSamples(discardFromIndex: 3)
        #expect(sampleQueue.getLargestReadTimestamp() == sampleTimestamps[2])
        sampleQueue.discardToRead()
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
            format: format2.buildUpon().setSubsampleOffsetUs(sampleOffsetUs).build()
        )
        try assertReadSample(
            timeUs: unadjustedTimestampUs + sampleOffsetUs,
            isKeyFrame: false,
            sampleData: data,
            offset: 0,
            length: data.readableBytes
        )
        try assertReadEndOfStream(formatRequired: false)
    }

    @Test
    func adjustUpstreamFormat() throws {
        let label = "label"
        sampleQueue = MockSampleQueue(
            label: .usual(label: label),
            queue: playerSyncQueue,
            allocator: allocator
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
        sampleQueue = MockSampleQueue(
            label: .protected(protected: label),
            queue: playerSyncQueue,
            allocator: allocator
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
        try assertReadSample(timeUs: 0, isKeyFrame: true, sampleData: data, offset: 0, length: data.readableBytes)
        try assertReadFormat(
            formatRequired: false,
            format: Self.copyWithLabel(format: format1, label: "label2")
        )
        try assertReadSample(timeUs: 1, isKeyFrame: true, sampleData: data, offset: 0, length: data.readableBytes)
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
            length: data.readableBytes
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
            length: data.readableBytes
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
            format: formatSpliced.buildUpon().setSubsampleOffsetUs(sampleOffsetUs).build()
        )
        try assertReadSample(
            timeUs: spliceSampleTimeUs + sampleOffsetUs,
            isKeyFrame: true,
            sampleData: data,
            offset: 0,
            length: data.readableBytes
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
        data: ByteBuffer,
        sampleSizes: [Int],
        sampleOffsets: [Int],
        sampleTimestamps: [Int64],
        sampleFormats: [Format],
        sampleFlags: [SampleFlags]
    ) throws {
        try sampleQueue.sampleData(data: data, length: data.readableBytes)
        var format: Format?
        
        for index in 0..<sampleTimestamps.count {
            if sampleFormats[index] != format {
                sampleQueue.setFormat(sampleFormats[index])
                format = sampleFormats[index]
            }

            sampleQueue.sampleMetadata(
                time: sampleTimestamps[index],
                flags: sampleFlags[index],
                size: sampleSizes[index],
                offset: sampleOffsets[index]
            )
        }
    }

    private func writeSample(data: ByteBuffer, timestampUs: Int64, flags: SampleFlags) throws {
        try sampleQueue.sampleData(data: data, length: data.readableBytes)
        sampleQueue.sampleMetadata(time: timestampUs, flags: flags, size: data.readableBytes, offset: 0)
    }

    private func writeAndDiscardPlaceholderSamples(sampleCount: Int) throws {
        sampleQueue.setFormat(formatSyncSampleOnly1)
        for _ in 0..<sampleCount {
            try writeSample(data: ByteBuffer(), timestampUs: 0, flags: .keyframe)
        }
        sampleQueue.discardToEnd()
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
        startFormat: Format? = nil,
        firstSampleIndex: Int = 0,
        sampleCount: Int? = nil,
        sampleOffsetUs: Int64 = 0,
        sampleFormats: [Format]? = nil,
        sampleFlags: [SampleFlags]? = nil
    ) throws {
        let sampleCount = sampleCount ?? sampleTimestamps.count - firstSampleIndex
        let sampleFormats = sampleFormats ?? self.sampleFormats
        let sampleFlags = sampleFlags ?? self.sampleFlags

        var format = adjustFormat(format: startFormat, sampleOffsetUs: sampleOffsetUs)
        for i in firstSampleIndex..<(firstSampleIndex + sampleCount) {
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
                offset: data.readableBytes - sampleOffsets[i] - sampleSizes[i],
                length: sampleSizes[i]
            )
        }
    }

    private func assertNoSamplesToRead(endFormat: Format?) throws {
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

    private func assertReadFormat(formatRequired: Bool, format: Format) throws {
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
                return readedFormat == format
            } else {
                return false
            }
        }())

        // inputBuffer should not be populated.
        assertInputBufferContainsNoSampleData()
        assertInputBufferHasNoDefaultFlagsSet()
    }
    
    private func assertReadSample(
        timeUs: Int64,
        isKeyFrame: Bool,
        sampleData: ByteBuffer,
        offset: Int,
        length: Int
    ) throws {
        // Check that peek whilst omitting data yields the expected values.
        let flagsOnlyBuffer = DecoderInputBuffer()
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
        sampleData: ByteBuffer,
        offset: Int,
        length: Int
    ) throws {
        // Check that peek whilst omitting data yields the expected values.
        let flagsOnlyBuffer = DecoderInputBuffer()
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
        inputBuffer: DecoderInputBuffer,
        result: SampleStreamReadResult,
        timeUs: Int64,
        isKeyFrame: Bool,
        isLastSample: Bool
    ) {
        #expect(result == .didReadBuffer)
        #expect(inputBuffer.time == timeUs)
        #expect(inputBuffer.flags.contains(.keyframe) == isKeyFrame)
        #expect(inputBuffer.flags.contains(.lastSample) == isLastSample)
    }

    private func assertSampleBufferReadResult(
        result: SampleStreamReadResult,
        timeUs: Int64,
        isKeyFrame: Bool,
        isLastSample: Bool,
        sampleData: ByteBuffer,
        offset: Int,
        length: Int
    ) throws {
        assertSampleBufferReadResult(inputBuffer: inputBuffer, result: result, timeUs: timeUs, isKeyFrame: isKeyFrame, isLastSample: isLastSample)
        #expect(inputBuffer.size == length)
        let buffer = try inputBuffer.dequeue()

        let range = offset..<(offset + length)
        for (index, byte) in sampleData.readableBytesView[range].enumerated() {
            #expect(buffer[index] == byte)
        }
    }

    private func assertAllocationCount(count: Int) {
        #expect(allocator.totalBytesAllocated == allocationSize * count)
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
        let buffer = UnsafeMutableRawBufferPointer(
            UnsafeMutableBufferPointer<UInt8>.allocate(capacity: dataCapacity)
        )
        if let oldBuffer = try? inputBuffer.dequeue() {
            oldBuffer.deallocate()
        }
        inputBuffer.reset()
        inputBuffer.enqueue(buffer: buffer)
    }

    private func adjustFormat(format: Format?, sampleOffsetUs: Int64) -> Format? {
        if format == nil || sampleOffsetUs == 0 {
            format
        } else {
            format?.buildUpon().setSubsampleOffsetUs(sampleOffsetUs).build()
        }
    }

    private func buildFormat(id: String) -> Format {
        Format.Builder().setId(id).setSubsampleOffsetUs(0).build()
    }

    nonisolated static func copyWithLabel(format: Format, label: String) -> Format {
        format.buildUpon().setLabel(label).build()
    }
}

private final class MockSampleQueue: SampleQueue {
    enum LabelVariant {
        case usual(label: String)
        case protected(protected: AtomicReference<String>)
    }

    let label: LabelVariant

    init(label: LabelVariant, queue: Queue, allocator: Allocator) {
        self.label = label

        super.init(queue: queue, allocator: allocator)
    }

    override func getAdjustedUpstreamFormat(_ format: Format) -> Format {
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
