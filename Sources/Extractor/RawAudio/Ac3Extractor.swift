//
//  Ac3Extractor.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Extracts data from (E-)AC-3 bitstreams.
public final class Ac3Extractor: Extractor {
    private let reader: Ac3Reader

    private var firstSampleTime: CMTime
    private var startedPacket = false

    /// - Parameter firstSampleTime: The time of the first sample, as for HLS packed audio.
    public init(firstSampleTime: CMTime = .zero) throws {
        self.firstSampleTime = firstSampleTime
        reader = try Ac3Reader(containerMimeType: .audioAC3)
    }

    public func sniff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        let startPosition = try await RawAudioExtractorSupport.peekPastId3Tags(input: input, isolation)
        var headerPosition = startPosition
        var validFramesCount = 0
        while true {
            guard let header = try await input.peekReader(length: 6, isolation) else { return false }
            if try header.getInt(at: 0, as: UInt16.self) != Self.syncWord {
                validFramesCount = 0
                input.resetPeekPosition(isolation)
                headerPosition += 1
                if headerPosition - startPosition >= RawAudioExtractorSupport.maxSniffBytes {
                    return false
                }
                try input.advancePeekPosition(length: headerPosition, isolation)
            } else {
                validFramesCount += 1
                if validFramesCount >= 4 {
                    return true
                }
                guard let frameSize = Ac3Util.parseAc3SyncFrameSize(header.bytesView) else { return false }
                try input.advancePeekPosition(length: frameSize - 6, isolation)
            }
        }
    }

    public func initialize(output: any ExtractorOutput, _ isolation: isolated any Actor) async throws {
        try reader.createTracks(output: output, idGenerator: TsPayload.TrackIdGenerator(firstTrackId: 0, trackIdIncrement: 1))
        output.endTracks()
        output.seekMap(seekMap: Unseekable(duration: .invalid))
    }

    public func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        guard var data = try await RawAudioExtractorSupport.read(input: input, length: Self.maxSyncFrameSize, isolation) else {
            return .endOfInput
        }
        if !startedPacket {
            reader.packetStarted(pesTime: firstSampleTime, decodeTime: .invalid, flags: .dataAlignment)
            startedPacket = true
        }
        try reader.consume(data: &data)
        return .continueRead
    }

    public func seek(to position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        startedPacket = false
        reader.seek()
        firstSampleTime = time
    }
}

private extension Ac3Extractor {
    static let syncWord: UInt16 = 0x0B77
    static let maxSyncFrameSize = 2786
}
