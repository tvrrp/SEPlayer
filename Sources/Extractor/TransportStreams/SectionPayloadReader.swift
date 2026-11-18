//
//  SectionPayloadReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
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
