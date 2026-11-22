//
//  PassthroughSectionPayloadReader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.PassthroughSectionPayloadReader
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Writes each section, such as an SCTE-35 splice information section, as a sample of a metadata track, at the time
/// of the last packet read.
final class PassthroughSectionPayloadReader: SectionPayloadReader {
    private let format: MetadataFormat

    private var session: TimestampAdjuster.Session?
    private var output: TrackOutput?

    init(sampleMimeType: MimeTypes, containerMimeType: MimeTypes) {
        format = MetadataFormat {
            $0.containerMimeType = containerMimeType
            $0.codec = sampleMimeType
        }
    }

    func initialize(
        session: TimestampAdjuster.Session,
        extractorOutput: ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator
    ) throws {
        self.session = session
        idGenerator.generateNewId()
        let output = try extractorOutput.track(for: idGenerator.getTrackId(), trackType: .metadata)
        let formatId = try idGenerator.getFormatId()
        try output.setFormat(AnyFormat(format.with { $0.id = formatId }))
        self.output = output
    }

    func consume(sectionData: inout BlockBufferReader) throws {
        let output = try output.checkNotNil()
        let sampleTime = try session.checkNotNil().lastAdjustedTime
        let sampleSize = sectionData.readableBytes
        guard sampleTime.isNumeric, sampleSize > 0 else {
            sectionData.moveReaderIndex(forwardBy: sampleSize)
            return
        }
        try output.sampleData(data: sectionData.readSlice(length: sampleSize).blockBuffer)
        try output.sampleMetadata(
            SampleProperties(
                timingInfo: CMSampleTimingInfo(
                    duration: .zero,
                    presentationTimeStamp: sampleTime,
                    decodeTimeStamp: .invalid
                ),
                dataRange: 0 ..< sampleSize,
                flags: .keyframe
            )
        )
    }
}
