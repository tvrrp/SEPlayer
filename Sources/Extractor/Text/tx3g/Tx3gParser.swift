//
//  Tx3gParser.swift
//  SEPlayer
//
//  Created by tvrrp on 25.02.2026.
//

import Foundation
import SEPlayerCommon

public final class Tx3gParser: SubtitleParser {
    public static let cueReplacementBehavior = Format.CueReplacementBehavior.replace

    private let defaultFontFace: UInt8
    private let defaultColorRgba: Int

    init(initializationData: [ByteBuffer]) throws {
        if initializationData.count == 1, (initializationData[0].readableBytes == 48 || initializationData[0].readableBytes == 53) {
            let initializationBytes = initializationData[0].readableBytesView
            defaultFontFace = initializationBytes[24]
            defaultColorRgba = 0
            let fontFamily = String(decoding: initializationBytes[43...], as: UTF8.self)
            print()
        } else {
            defaultFontFace = 0
            defaultColorRgba = 0
        }
    }

    public func getCueReplacementBehavior() -> Format.CueReplacementBehavior {
        Self.cueReplacementBehavior
    }

    public func parse(
        data: inout ByteBuffer,
        offset: Int,
        lenght: Int,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws {
        data.moveReaderIndex(to: offset)
        let cueTextString = try readSubtitleText(data: &data)
        if cueTextString.isEmpty {
            try output(CuesWithTiming(
                cues: [],
                startTimeUs: .timeUnset,
                durationUs: .timeUnset
            ))
        }

        let cue = Cue.Builder()
            .setText(cueTextString)
            .build()

        try output(CuesWithTiming(
            cues: [cue],
            startTimeUs: .timeUnset,
            durationUs: .timeUnset
        ))
    }

    private func readSubtitleText(data: inout ByteBuffer) throws -> String {
        try checkArgument(data.readableBytes >= 2)
        let textLength = try Int(data.readInt(as: UInt16.self))
        if textLength == 0 {
            return ""
        }

        let textStartPosition = data.readerIndex
        let encoding = data.readUtfCharsetFromBom()
        let bomSize = data.readerIndex - textStartPosition
        return try data.readString(length: textLength - bomSize, encoding: encoding ?? .utf8)
    }
}
