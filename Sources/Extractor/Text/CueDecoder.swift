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
                builder.setText(try decodeText(&payload))
                hasContent = true
            case .image:
                builder.setImage(try payload.readImage())
                hasContent = true
            case .textAlignment:
                builder.setTextAlignment(Cue.Alignment(rawValue: try payload.read()))
            case .multiRowAlignment:
                builder.setMultiRowAlignment(Cue.Alignment(rawValue: try payload.read()))
            case .line:
                switch try payload.read(as: UInt8.self) {
                case 0: builder.setLine(.fraction(try payload.readCGFloat()))
                case 1: builder.setLine(.number(Int(try payload.read(as: Int64.self))))
                default: break
                }
            case .lineAnchor:
                builder.setLineAnchor(Cue.Anchor(rawValue: try payload.read()))
            case .position:
                builder.setPosition(try payload.readCGFloat())
            case .positionAnchor:
                builder.setPositionAnchor(Cue.Anchor(rawValue: try payload.read()))
            case .size:
                builder.setSize(try payload.readCGFloat())
            case .imageHeight:
                builder.setImageHeight(try payload.readCGFloat())
            case .windowColor:
                builder.setWindowColor(try payload.readColor())
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
                builder.setVerticalType(Cue.VerticalType(rawValue: try payload.read()))
            case .shearDegrees:
                builder.setShearDegrees(try payload.readCGFloat())
            case .zIndex:
                builder.setZIndex(Int(try payload.read(as: Int32.self)))
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
                let location = Int(try payload.read(as: UInt32.self))
                let length = Int(try payload.read(as: UInt32.self))
                spans.append((location, length, try decodeAttributes(&payload)))
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
            text[start..<end].mergeAttributes(span.attributes)
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
                let position = Cue.AnnotationPosition(rawValue: try payload.read())
                attributes.cueRuby = Cue.Ruby(text: try payload.readString(), position: position)
            case .textEmphasis:
                let markShape = Cue.TextEmphasis.MarkShape(rawValue: try payload.read()) ?? .none
                let markFill = Cue.TextEmphasis.MarkFill(rawValue: try payload.read())
                let position = Cue.AnnotationPosition(rawValue: try payload.read())
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
