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
        idGenerator: TsPayload.TrackIdGenerator
    ) throws
    func packetStarted(
        pesTime: CMTime,
        decodeTime: CMTime,
        flags: TsPayload.PacketIndicators
    )
    func consume(data: inout BlockBufferReader) throws
    func packetFinished() throws
    func endOfInputReached() throws
}

public extension ElementaryStreamReader {
    func packetFinished() throws {}
    func endOfInputReached() throws {}
}
