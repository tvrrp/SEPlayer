//
//  ElementaryStreamReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

import CoreMedia
import SEPlayerCommon

public protocol ElementaryStreamReader {
    func seek()
    func createTracks(
        output: ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator,
        _ isolation: isolated any Actor
    ) async throws
    func packetStarted(
        pesTime: CMTime,
        decodeTime: CMTime,
        flags: TsPayload.PacketIndicators
    )
    func consume(data: inout BlockBufferReader, _ isolation: isolated any Actor) async throws
    func packetFinished(_ isolation: isolated any Actor) async throws
    func endOfInputReached(_ isolation: isolated any Actor) async throws
}

public extension ElementaryStreamReader {
    func packetFinished(_ isolation: isolated any Actor) async throws {}
    func endOfInputReached(_ isolation: isolated any Actor) async throws {}
}
