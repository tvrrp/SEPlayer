//
//  SubtitleParser.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import SEPlayerCommon

public protocol SubtitleParserFactory {
    func supportsFormat(_ format: Format) -> Bool
    func getCueReplacementBehavior(format: Format) throws -> Format.CueReplacementBehavior
    func create(format: Format) throws -> SubtitleParser
}

public protocol SubtitleParser {
    func parse(
        data: inout ByteBuffer,
        outputOptions: SubtitleParserOutputOptions,
        output: @escaping (CuesWithTiming) throws -> Void
    ) throws
    func parse(
        data: inout ByteBuffer,
        offset: Int,
        lenght: Int,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws
    func reset()
    func getCueReplacementBehavior() -> Format.CueReplacementBehavior
}

public extension SubtitleParser {
    func parse(
        data: inout ByteBuffer,
        outputOptions: SubtitleParserOutputOptions,
        output: @escaping (CuesWithTiming) throws -> Void
    ) throws {
        try parse(
            data: &data,
            offset: .zero,
            lenght: data.readableBytes,
            outputOptions: outputOptions,
            output: output
        )
    }

    func reset() {}
}

public struct SubtitleParserOutputOptions {
    public let startTimeUs: Int64
    public let outputAllCues: Bool

    private init(startTimeUs: Int64, outputAllCues: Bool) {
        self.startTimeUs = startTimeUs
        self.outputAllCues = outputAllCues
    }

    public static func allCues() -> Self {
        SubtitleParserOutputOptions(startTimeUs: .timeUnset, outputAllCues: false)
    }

    public static func onlyCuesAfter(startTimeUs: Int64) -> Self {
        SubtitleParserOutputOptions(startTimeUs: startTimeUs, outputAllCues: false)
    }

    public static func cuesAfterThenRemainingCuesBefore(startTimeUs: Int64) -> Self {
        SubtitleParserOutputOptions(startTimeUs: .timeUnset, outputAllCues: true)
    }
}
