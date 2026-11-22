//
//  SectionPayloadReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.SectionPayloadReader
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

public protocol SectionPayloadReader {
    func initialize(
        session: TimestampAdjuster.Session,
        extractorOutput: ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator
    ) throws

    func consume(sectionData: inout BlockBufferReader) throws
}
