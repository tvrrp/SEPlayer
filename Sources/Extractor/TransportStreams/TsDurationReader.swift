//
//  TsDurationReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.08.2026.
//

import CoreMedia
import SEPlayerCommon

/// A reader that can extract the approximate duration from a given MPEG transport stream (TS).
///
/// This reader extracts the duration by reading PCR values of the PCR PID packets at the start
/// and at the end of the stream, calculating the difference, and converting that into stream
/// duration. This reader also handles the case when a single PCR wraparound takes place within the
/// stream, which can make PCR values at the beginning of the stream larger than PCR values at the
/// end. This class can only be used once to read duration from a given stream, and the usage of the
/// class is not thread-safe, so all calls should be made from the same thread.
final class TsDurationReader {
    private let timestampSearchBytes: Int
    private var pcrUnwrapper = PtsUnwrapper()

//    private var packetBuffer: BlockBufferReader?

    private var isDurationRead = false
    private var isFirstPcrValueRead = false
    private var isLastPcrValueRead = false

    private var firstPcrValue: Int64?
    private var lastPcrValue: Int64?
    private var duration: CMTime = .invalid

    init(timestampSearchBytes: Int) {
        self.timestampSearchBytes = timestampSearchBytes
    }

    /// Returns true if a TS duration has been read.
    var isDurationReadFinished: Bool { isDurationRead }

    /// Reads a TS duration from the input, using the given PCR PID.
    ///
    /// This reader reads the duration by reading PCR values of the PCR PID packets at the start and
    /// at the end of the stream, calculating the difference, and converting that into stream
    /// duration.
    func readDuration(
        input: any ExtractorInput,
        pcrPid: Int,
        _ isolation: isolated any Actor
    ) async throws -> ExtractorReadResult {
        if pcrPid <= 0 {
            return finishReadDuration(input: input, isolation)
        }
        if !isLastPcrValueRead {
            return try await readLastPcrValue(input: input, pcrPid: pcrPid, isolation)
        }
        guard let lastPcrValue else {
            return finishReadDuration(input: input, isolation)
        }
        if !isFirstPcrValueRead {
            return try await readFirstPcrValue(input: input, pcrPid: pcrPid, isolation)
        }
        guard let firstPcrValue else {
            return finishReadDuration(input: input, isolation)
        }

        let minPcrPosition = CMTime(
            value: pcrUnwrapper.unwrap(firstPcrValue),
            timescale: 90_000
        )
        let maxPcrPosition = CMTime(
            value: pcrUnwrapper.unwrapGreaterThanPrevious(lastPcrValue),
            timescale: 90_000
        )
        duration = maxPcrPosition - minPcrPosition
        return finishReadDuration(input: input, isolation)
    }

    /// Returns the duration last read from `readDuration(input:pcrPid:_:)`.
    func getDuration() -> CMTime { duration }

    private func finishReadDuration(
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) -> ExtractorReadResult {
//        packetBuffer = nil
        isDurationRead = true
        input.resetPeekPosition(isolation)
        return .continueRead
    }

    private func readFirstPcrValue(
        input: any ExtractorInput,
        pcrPid: Int,
        _ isolation: isolated any Actor
    ) async throws -> ExtractorReadResult {
        guard let inputLength = input.getLength(isolation) else {
            return finishReadDuration(input: input, isolation)
        }
        let bytesToSearch = min(timestampSearchBytes, inputLength)
        if input.getPosition(isolation) != 0 {
            return .seek(offset: 0)
        }

        input.resetPeekPosition(isolation)
        var packetBuffer = try await BlockBufferReader(
            input.peekFully(length: bytesToSearch, isolation)
        )
//        print(searchStartPosition)
//        self.packetBuffer = packetBuffer

        firstPcrValue = try readFirstPcrValueFromBuffer(&packetBuffer, pcrPid: pcrPid)
        isFirstPcrValueRead = true
        return .continueRead
    }

    private func readFirstPcrValueFromBuffer(
        _ packetBuffer: inout BlockBufferReader,
        pcrPid: Int
    ) throws -> Int64? {
        let searchStartPosition = packetBuffer.readerIndex
        let searchEndPosition = packetBuffer.capacity
        for searchPosition in searchStartPosition ..< searchEndPosition {
            if try packetBuffer.getInt(at: searchPosition, as: UInt8.self) != TSConstants.syncByte {
                continue
            }
            if let pcrValue = try TsUtil.readPcrFromPacket(
                packetBuffer,
                startOfPacket: searchPosition,
                pcrPid: pcrPid
            ) {
                return pcrValue
            }
        }
        return nil
    }

    private func readLastPcrValue(
        input: any ExtractorInput,
        pcrPid: Int,
        _ isolation: isolated any Actor
    ) async throws -> ExtractorReadResult {
        guard let inputLength = input.getLength(isolation) else {
            return finishReadDuration(input: input, isolation)
        }
        let bytesToSearch = min(timestampSearchBytes, inputLength)
        let searchStartPosition = inputLength - bytesToSearch
        if input.getPosition(isolation) != searchStartPosition {
            return .seek(offset: searchStartPosition)
        }

        input.resetPeekPosition(isolation)
        var packetBuffer = try await BlockBufferReader(
            input.peekFully(length: bytesToSearch, isolation)
        )
//        self.packetBuffer = packetBuffer

        lastPcrValue = try readLastPcrValueFromBuffer(&packetBuffer, pcrPid: pcrPid)
        isLastPcrValueRead = true
        return .continueRead
    }

    private func readLastPcrValueFromBuffer(
        _ packetBuffer: inout BlockBufferReader,
        pcrPid: Int
    ) throws -> Int64? {
        let searchStartPosition = packetBuffer.readerIndex
        let searchEndPosition = packetBuffer.capacity
        // We start searching 'TSConstants.tsPacketSize' bytes from the end to prevent trying to read
        // from an incomplete TS packet.
        var searchPosition = searchEndPosition - Int(TSConstants.syncByte)
        while searchPosition >= searchStartPosition {
            if try !TsUtil.isStartOfTsPacket(
                packetBuffer,
                startPosition: searchStartPosition,
                limitPosition: searchEndPosition,
                position: searchPosition
            ) {
                searchPosition -= 1
                continue
            }
            if let pcrValue = try TsUtil.readPcrFromPacket(
                packetBuffer,
                startOfPacket: searchPosition,
                pcrPid: pcrPid
            ) {
                return pcrValue
            }
            searchPosition -= 1
        }
        return nil
    }
}
