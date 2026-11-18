//
//  CueDecoder.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//

import CoreGraphics
import CoreMedia
import Foundation
import SEPlayerCommon

/// Decodes the payload of a cue sample that `CueEncoder` encoded.
public struct CueDecoder {
    public init() {}

    /// Decodes the cues of a sample that starts at `startTime`.
    public func decode(startTime: CMTime, data: CMBlockBuffer) throws -> CuesWithTiming {
        var cues: [Cue] = []
        var duration = CMTime.invalid

        var reader = CueBoxReader(BlockBufferReader(data))
        try reader.forEachBox { type, payload in
            guard type == .cues else { return }
            try payload.forEachBox { type, payload in
                switch type {
                case .duration:
                    duration = try payload.readTime()
                case .cue:
                    if let cue = try decodeCue(&payload) { cues.append(cue) }
                default:
                    break
                }
            }
        }

        return CuesWithTiming(cues: cues, startTime: startTime, duration: duration)
    }

    /// Returns `nil` for a cue with neither text nor an image.
    private func decodeCue(_ reader: inout CueBoxReader) throws -> Cue? {
        let builder = Cue.Builder()
        var hasContent = false

        try reader.forEachBox { type, payload in
            switch type {
            case .text:
                try builder.setText(decodeText(&payload))
                hasContent = true
            case .image:
                try builder.setImage(payload.readImage())
                hasContent = true
            case .textAlignment:
                try builder.setTextAlignment(Cue.Alignment(rawValue: payload.read()))
            case .multiRowAlignment:
                try builder.setMultiRowAlignment(Cue.Alignment(rawValue: payload.read()))
            case .line:
                switch try payload.read(as: UInt8.self) {
                case 0: try builder.setLine(.fraction(payload.readCGFloat()))
                case 1: try builder.setLine(.number(Int(payload.read(as: Int64.self))))
                default: break
                }
            case .lineAnchor:
                try builder.setLineAnchor(Cue.Anchor(rawValue: payload.read()))
            case .position:
                try builder.setPosition(payload.readCGFloat())
            case .positionAnchor:
                try builder.setPositionAnchor(Cue.Anchor(rawValue: payload.read()))
            case .size:
                try builder.setSize(payload.readCGFloat())
            case .imageHeight:
                try builder.setImageHeight(payload.readCGFloat())
            case .windowColor:
                try builder.setWindowColor(payload.readColor())
            case .textSize:
                let kind = try payload.read(as: UInt8.self)
                let size = try payload.readCGFloat()
                switch kind {
                case 0: builder.setTextSize(.fractional(size))
                case 1: builder.setTextSize(.fractionalIgnoringPadding(size))
                case 2: builder.setTextSize(.absolute(size))
                default: break
                }
            case .verticalType:
                try builder.setVerticalType(Cue.VerticalType(rawValue: payload.read()))
            case .shearDegrees:
                try builder.setShearDegrees(payload.readCGFloat())
            case .zIndex:
                try builder.setZIndex(Int(payload.read(as: Int32.self)))
            default:
                break
            }
        }

        return hasContent ? builder.build() : nil
    }

    private func decodeText(_ reader: inout CueBoxReader) throws -> AttributedString {
        var string = ""
        var spans: [(location: Int, length: Int, attributes: AttributeContainer)] = []

        try reader.forEachBox { type, payload in
            switch type {
            case .string:
                string = try payload.readString()
            case .span:
                let location = try Int(payload.read(as: UInt32.self))
                let length = try Int(payload.read(as: UInt32.self))
                try spans.append((location, length, decodeAttributes(&payload)))
            default:
                break
            }
        }

        var text = AttributedString(string)
        let scalars = text.unicodeScalars
        let scalarCount = scalars.count
        for span in spans where span.location + span.length <= scalarCount {
            let start = scalars.index(scalars.startIndex, offsetBy: span.location)
            let end = scalars.index(start, offsetBy: span.length)
            text[start ..< end].mergeAttributes(span.attributes)
        }
        return text
    }

    private func decodeAttributes(_ reader: inout CueBoxReader) throws -> AttributeContainer {
        var attributes = AttributeContainer()

        try reader.forEachBox { type, payload in
            switch type {
            case .foregroundColor:
                attributes.cueForegroundColor = try payload.readColor()
            case .backgroundColor:
                attributes.cueBackgroundColor = try payload.readColor()
            case .underline:
                attributes.cueUnderline = try payload.readBool()
            case .strikethrough:
                attributes.cueStrikethrough = try payload.readBool()
            case .bold:
                attributes.cueBold = try payload.readBool()
            case .italic:
                attributes.cueItalic = try payload.readBool()
            case .fontFamily:
                attributes.cueFontFamily = try payload.readString()
            case .relativeFontSize:
                attributes.cueRelativeFontSize = try payload.readCGFloat()
            case .absoluteFontSize:
                attributes.cueAbsoluteFontSize = try payload.readCGFloat()
            case .ruby:
                let position = try Cue.AnnotationPosition(rawValue: payload.read())
                attributes.cueRuby = try Cue.Ruby(text: payload.readString(), position: position)
            case .textEmphasis:
                let markShape = try Cue.TextEmphasis.MarkShape(rawValue: payload.read()) ?? .none
                let markFill = try Cue.TextEmphasis.MarkFill(rawValue: payload.read())
                let position = try Cue.AnnotationPosition(rawValue: payload.read())
                attributes.cueTextEmphasis = Cue.TextEmphasis(markShape: markShape, markFill: markFill, position: position)
            case .horizontalInVertical:
                attributes.cueHorizontalInVertical = try payload.readBool()
            case .voice:
                attributes.cueVoice = try payload.readString()
            default:
                break
            }
        }

        return attributes
    }
}
