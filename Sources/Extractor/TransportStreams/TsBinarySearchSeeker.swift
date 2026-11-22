//
//  TsBinarySearchSeeker.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.08.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.TsBinarySearchSeeker
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// A seeker that supports seeking within TS stream using binary search.
///
/// This seeker uses the first and last PCR values within the stream, as well as the stream
/// duration to interpolate the PCR value of the seeking position. Then it performs binary search
/// within the stream to find a packets whose PCR value is within `seekTolerance` from the target
/// PCR.
final class TsBinarySearchSeeker: BinarySearchSeeker {
    static let seekTolerance = CMTime(value: 9_000, timescale: 90_000)
    private static let minimumSearchRangeBytes = 5 * TSConstants.packetSize

    init(
        streamDuration: CMTime,
        inputLength: Int,
        pcrPid: Int,
        timestampSearchBytes: Int
    ) {
        super.init(
            seekTimestampConverter: DefaultSeekTimestampConverter(),
            timestampSeeker: TsPcrSeeker(
                pcrPid: pcrPid,
                timestampSearchBytes: timestampSearchBytes
            ),
            duration: streamDuration,
            floorTimePosition: .zero,
            ceilingTimePosition: CMTimeAdd(streamDuration, BinarySearchSeeker.timePositionEpsilon),
            floorBytePosition: 0,
            ceilingBytePosition: inputLength,
            approxBytesPerFrame: TSConstants.packetSize,
            minimumSearchRange: Self.minimumSearchRangeBytes
        )
    }
}

/// A `TimestampSeeker` implementation that looks for a given PCR timestamp at a given position in
/// a TS stream.
///
/// Given a PCR timestamp, and a position within a TS stream, this seeker will peek up to
/// `timestampSearchBytes` from that stream position, look for all packets with PID equal to
/// PCR_PID, and then compare the PCR timestamps (if available) of these packets to the target
/// timestamp.
private final class TsPcrSeeker: TimestampSeeker {
    private let pcrPid: Int
    private let timestampSearchBytes: Int

    private var pcrUnwrapper = PtsUnwrapper()
    private var packetBuffer: BlockBufferReader?

    init(pcrPid: Int, timestampSearchBytes: Int) {
        self.pcrPid = pcrPid
        self.timestampSearchBytes = timestampSearchBytes
    }

    func searchForTimestamp(
        input: any ExtractorInput,
        targetTimestamp: CMTime,
        _ isolation: isolated any Actor
    ) async throws -> TimestampSearchResult {
        let inputPosition = input.getPosition(isolation)
        guard let inputLength = input.getLength(isolation) else {
            return .noTimestamp
        }
        let bytesToSearch = min(timestampSearchBytes, inputLength - inputPosition)

        var packetBuffer = try await BlockBufferReader(
            input.peekFully(length: bytesToSearch, isolation)
        )
        self.packetBuffer = packetBuffer

        return try searchForPcrValueInBuffer(
            &packetBuffer,
            targetPcrTime: targetTimestamp,
            bufferStartOffset: inputPosition
        )
    }

    private func searchForPcrValueInBuffer(
        _ packetBuffer: inout BlockBufferReader,
        targetPcrTime: CMTime,
        bufferStartOffset: Int
    ) throws -> TimestampSearchResult {
        let limit = packetBuffer.capacity

        var startOfLastPacketPosition: Int?
        var endOfLastPacketPosition: Int?
        var lastPcrTimeInRange: CMTime?

        while packetBuffer.readableBytes >= TSConstants.packetSize {
            let startOfPacket = try TsUtil.findSyncBytePosition(
                packetBuffer,
                startPosition: packetBuffer.readerIndex,
                limitPosition: limit
            )
            let endOfPacket = startOfPacket + TSConstants.packetSize
            if endOfPacket > limit {
                break
            }
            let pcrValue = try TsUtil.readPcrFromPacket(
                packetBuffer,
                startOfPacket: startOfPacket,
                pcrPid: pcrPid
            )
            if let pcrValue {
                let pcrTime = CMTime(
                    value: pcrUnwrapper.unwrap(pcrValue),
                    timescale: 90_000
                )

                if pcrTime > targetPcrTime {
                    guard let startOfLastPacketPosition else {
                        // First PCR timestamp is already over target.
                        return .overestimated(
                            timestamp: pcrTime,
                            bytePosition: bufferStartOffset
                        )
                    }
                    // Last PCR timestamp < target timestamp < this timestamp.
                    return .targetFound(
                        bytePosition: bufferStartOffset + startOfLastPacketPosition
                    )
                } else if CMTimeAdd(pcrTime, TsBinarySearchSeeker.seekTolerance) > targetPcrTime {
                    let startOfPacketInStream = bufferStartOffset + startOfPacket
                    return .targetFound(bytePosition: startOfPacketInStream)
                }

                lastPcrTimeInRange = pcrTime
                startOfLastPacketPosition = startOfPacket
            }
            packetBuffer.moveReaderIndex(to: endOfPacket)
            endOfLastPacketPosition = endOfPacket
        }

        if let lastPcrTimeInRange, let endOfLastPacketPosition {
            let endOfLastPacketPositionInStream = bufferStartOffset + endOfLastPacketPosition
            return .underestimated(
                timestamp: lastPcrTimeInRange,
                bytePosition: endOfLastPacketPositionInStream
            )
        } else {
            return .noTimestamp
        }
    }

    func onSeekFinished(_ isolation: isolated any Actor) {
        packetBuffer = nil
    }
}
