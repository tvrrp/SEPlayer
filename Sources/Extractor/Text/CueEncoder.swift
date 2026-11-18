//
//  CueEncoder.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//

import CoreGraphics
import CoreMedia
import Foundation
import SEPlayerCommon

/// Encodes cues into the payload of a cue sample, laid out as `CueBox` describes.
public struct CueEncoder {
    public init() {}

    /// Encodes `cues` that last `duration`. The start time is the sample time.
    public func encode(cues: [Cue], duration: CMTime) throws -> CMBlockBuffer {
        var writer = CueBoxWriter()
        try writer.box(.cues) { writer in
            try writer.box(.duration) { $0.append(duration) }
            for cue in cues {
                try writer.box(.cue) { try encode(cue, to: &$0) }
            }
        }
        return try makeBlockBuffer(copying: writer.bytes)
    }

    private func encode(_ cue: Cue, to writer: inout CueBoxWriter) throws {
        if let text = cue.text {
            try writer.box(.text) { try encode(text, to: &$0) }
        }
        if let image = cue.image {
            try writer.box(.image) { try $0.append(image) }
        }
        if let textAlignment = cue.textAlignment {
            try writer.box(.textAlignment) { $0.append(textAlignment.rawValue) }
        }
        if let multiRowAlignment = cue.multiRowAlignment {
            try writer.box(.multiRowAlignment) { $0.append(multiRowAlignment.rawValue) }
        }
        if let line = cue.line {
            try writer.box(.line) { writer in
                switch line {
                case let .fraction(fraction):
                    writer.append(UInt8(0))
                    writer.append(fraction)
                case let .number(number):
                    writer.append(UInt8(1))
                    writer.append(Int64(number))
                }
            }
        }
        if let lineAnchor = cue.lineAnchor {
            try writer.box(.lineAnchor) { $0.append(lineAnchor.rawValue) }
        }
        if let position = cue.position {
            try writer.box(.position) { $0.append(position) }
        }
        if let positionAnchor = cue.positionAnchor {
            try writer.box(.positionAnchor) { $0.append(positionAnchor.rawValue) }
        }
        if let size = cue.size {
            try writer.box(.size) { $0.append(size) }
        }
        if let imageHeight = cue.imageHeight {
            try writer.box(.imageHeight) { $0.append(imageHeight) }
        }
        if let windowColor = cue.windowColor {
            try writer.box(.windowColor) { try $0.append(windowColor) }
        }
        if let textSize = cue.textSize {
            try writer.box(.textSize) { writer in
                switch textSize {
                case let .fractional(size):
                    writer.append(UInt8(0))
                    writer.append(size)
                case let .fractionalIgnoringPadding(size):
                    writer.append(UInt8(1))
                    writer.append(size)
                case let .absolute(size):
                    writer.append(UInt8(2))
                    writer.append(size)
                }
            }
        }
        if let verticalType = cue.verticalType {
            try writer.box(.verticalType) { $0.append(verticalType.rawValue) }
        }
        if cue.shearDegrees != 0 {
            try writer.box(.shearDegrees) { $0.append(cue.shearDegrees) }
        }
        if cue.zIndex != 0 {
            try writer.box(.zIndex) { $0.append(Int32(clamping: cue.zIndex)) }
        }
    }

    /// Writes the string, then a span for each run with attributes. Spans count Unicode scalars.
    private func encode(_ text: AttributedString, to writer: inout CueBoxWriter) throws {
        try writer.box(.string) { $0.append(String(text.characters)) }

        let scalars = text.unicodeScalars
        for run in text.runs {
            var attributesWriter = CueBoxWriter()
            try encode(run, to: &attributesWriter)
            guard !attributesWriter.bytes.isEmpty else { continue }

            let location = scalars.distance(from: scalars.startIndex, to: run.range.lowerBound)
            let length = scalars.distance(from: run.range.lowerBound, to: run.range.upperBound)
            try writer.box(.span) { writer in
                writer.append(UInt32(location))
                writer.append(UInt32(length))
                writer.append(bytes: attributesWriter.bytes)
            }
        }
    }

    /// Writes the cue attributes of the run.
    private func encode(_ run: AttributedString.Runs.Run, to writer: inout CueBoxWriter) throws {
        if let color = run.cueForegroundColor {
            try writer.box(.foregroundColor) { try $0.append(color) }
        }
        if let color = run.cueBackgroundColor {
            try writer.box(.backgroundColor) { try $0.append(color) }
        }
        if let isOn = run.cueUnderline {
            try writer.box(.underline) { $0.append(isOn) }
        }
        if let isOn = run.cueStrikethrough {
            try writer.box(.strikethrough) { $0.append(isOn) }
        }
        if let isOn = run.cueBold {
            try writer.box(.bold) { $0.append(isOn) }
        }
        if let isOn = run.cueItalic {
            try writer.box(.italic) { $0.append(isOn) }
        }
        if let family = run.cueFontFamily {
            try writer.box(.fontFamily) { $0.append(family) }
        }
        if let size = run.cueRelativeFontSize {
            try writer.box(.relativeFontSize) { $0.append(size) }
        }
        if let size = run.cueAbsoluteFontSize {
            try writer.box(.absoluteFontSize) { $0.append(size) }
        }
        if let ruby = run.cueRuby {
            try writer.box(.ruby) { writer in
                writer.append(ruby.position?.rawValue ?? 0)
                writer.append(ruby.text)
            }
        }
        if let emphasis = run.cueTextEmphasis {
            try writer.box(.textEmphasis) { writer in
                writer.append(emphasis.markShape.rawValue)
                writer.append(emphasis.markFill?.rawValue ?? 0)
                writer.append(emphasis.position?.rawValue ?? 0)
            }
        }
        if let isOn = run.cueHorizontalInVertical {
            try writer.box(.horizontalInVertical) { $0.append(isOn) }
        }
        if let voice = run.cueVoice {
            try writer.box(.voice) { $0.append(voice) }
        }
    }
}

/// A block buffer holding a copy of `bytes`.
func makeBlockBuffer(copying bytes: [UInt8]) throws -> CMBlockBuffer {
    let blockBuffer = try CMBlockBuffer(length: bytes.count, flags: .assureMemoryNow)
    try bytes.withUnsafeBytes { try blockBuffer.replaceDataBytes(with: $0) }
    return blockBuffer
}
