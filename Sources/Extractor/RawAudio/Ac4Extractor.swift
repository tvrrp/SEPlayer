//
//  Ac4Extractor.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Extracts data from AC-4 bitstreams.
public final class Ac4Extractor: Extractor {
    private let reader: Ac4Reader

    private var firstSampleTime: CMTime
    private var startedPacket = false

    /// - Parameter firstSampleTime: The time of the first sample, as for HLS packed audio.
    public init(firstSampleTime: CMTime = .zero) throws {
        self.firstSampleTime = firstSampleTime
        reader = try Ac4Reader(containerMimeType: .audioAC4)
    }

    public func sniff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        let startPosition = try await RawAudioExtractorSupport.peekPastId3Tags(input: input, isolation)
        var headerPosition = startPosition
        var validFramesCount = 0
        while true {
            guard let header = try await input.peekReader(length: 7, isolation) else { return false }
            let syncBytes = try Int(header.getInt(at: 0, as: UInt16.self))
            if syncBytes != Ac4Util.ac40SyncWord, syncBytes != Ac4Util.ac41SyncWord {
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
                guard let frameSize = Ac4Util.parseAc4SyncFrameSize(header.bytesView, syncWord: syncBytes) else { return false }
                try input.advancePeekPosition(length: frameSize - 7, isolation)
            }
        }
    }

    public func initialize(output: any ExtractorOutput, _ isolation: isolated any Actor) async throws {
        try reader.createTracks(output: output, idGenerator: TsPayload.TrackIdGenerator(firstTrackId: 0, trackIdIncrement: 1))
        output.endTracks()
        output.seekMap(seekMap: Unseekable(duration: .invalid))
    }

    public func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        guard var data = try await RawAudioExtractorSupport.read(input: input, length: Self.readBufferSize, isolation) else {
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

private extension Ac4Extractor {
    static let readBufferSize = 16384
}
