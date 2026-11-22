//
//  ElementaryStreamReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.ElementaryStreamReader
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
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
