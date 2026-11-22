//
//  Mp4WebvttParser.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.webvtt.Mp4WebvttParser
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// A ``SubtitleParser`` for WebVTT samples in MP4 (ISO/IEC 14496-30): each sample holds the cues that show for its
/// duration, as `vttc` boxes, or none, as an empty-cue box.
public final class Mp4WebvttParser: SubtitleParser {
    public static let cueReplacementBehavior = CueReplacementBehavior.replace

    public init() {}

    public func getCueReplacementBehavior() -> CueReplacementBehavior {
        Mp4WebvttParser.cueReplacementBehavior
    }

    public func parse(
        data: BlockBufferReader,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws {
        var data = data
        var cues: [Cue] = []
        while data.readableBytes > 0 {
            guard data.readableBytes >= MP4Box.headerSize else {
                throw ParserError.createForMalformedContainer(message: "Incomplete Mp4Webvtt top level box header found.")
            }
            let boxSize = try Int(data.readInt(as: UInt32.self))
            let boxType = try MP4Box.BoxType(rawValue: data.readInt(as: UInt32.self))
            let payloadSize = boxSize - MP4Box.headerSize
            guard payloadSize >= 0, payloadSize <= data.readableBytes else {
                throw ParserError.createForMalformedContainer(message: "Mp4Webvtt box is larger than the sample.")
            }
            if boxType == .vttc {
                try cues.append(parseVttCueBox(&data, remainingCueBoxBytes: payloadSize))
            } else {
                // The peers of the cue box aren't supported.
                data.moveReaderIndex(forwardBy: payloadSize)
            }
        }
        // The times are those of the sample.
        try output(CuesWithTiming(cues: cues, startTime: .invalid, duration: .invalid))
    }

    private func parseVttCueBox(_ data: inout BlockBufferReader, remainingCueBoxBytes: Int) throws -> Cue {
        var remaining = remainingCueBoxBytes
        var settingsCue: Cue?
        var cueText: AttributedString?
        while remaining > 0 {
            guard remaining >= MP4Box.headerSize else {
                throw ParserError.createForMalformedContainer(message: "Incomplete vtt cue box header found.")
            }
            let boxSize = try Int(data.readInt(as: UInt32.self))
            let boxType = try MP4Box.BoxType(rawValue: data.readInt(as: UInt32.self))
            remaining -= MP4Box.headerSize
            let payloadLength = boxSize - MP4Box.headerSize
            guard payloadLength >= 0, payloadLength <= remaining else {
                throw ParserError.createForMalformedContainer(message: "vtt cue box child is larger than the box.")
            }
            // Invalid UTF-8 becomes replacement characters rather than failing.
            // swiftlint:disable:next optional_data_string_conversion
            let payload = try String(decoding: data.readBytes(length: payloadLength), as: UTF8.self)
            remaining -= payloadLength
            if boxType == .sttg {
                settingsCue = WebvttCueParser.parseCueSettings(payload)
            } else if boxType == .payl {
                cueText = WebvttCueParser.parseCueText(
                    id: nil,
                    markup: payload.trimmingCharacters(in: .whitespacesAndNewlines),
                    styles: []
                )
            }
            // Other children of the cue box aren't supported.
        }
        let text = cueText ?? AttributedString()
        let cue = settingsCue ?? WebvttCueInfoBuilder().toCueBuilder().build()
        return cue.buildUpon().setText(text).build()
    }
}
