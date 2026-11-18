//
//  Tx3gParser.swift
//  SEPlayer
//
//  Created by tvrrp on 25.02.2026.
//

import CoreGraphics
import CoreMedia
import Foundation
import SEPlayerCommon

/// A `SubtitleParser` for tx3g.
///
/// Currently supports parsing of a single text track with embedded styles.
public final class Tx3gParser: SubtitleParser {
    /// The `Format.CueReplacementBehavior` for consecutive `CuesWithTiming` emitted by this implementation.
    public static let cueReplacementBehavior = Format.CueReplacementBehavior.replace

    private let customVerticalPlacement: Bool
    private let defaultFontFace: UInt8
    private let defaultColorRgba: UInt32
    private let defaultFontFamily: String
    private let defaultVerticalPlacement: CGFloat
    private let calculatedVideoTrackHeight: Int?

    /// Sets up a new `Tx3gParser` with default values.
    ///
    /// - Parameter initializationData: Sample description atom ('stsd') data with default subtitle styles.
    public init(initializationData: [BlockBufferReader]) throws {
        if initializationData.count == 1,
           initializationData[0].readableBytes == 48 || initializationData[0].readableBytes == 53 {
            let initializationBytes = try initializationData[0].getBytes(
                at: initializationData[0].readerIndex,
                length: initializationData[0].readableBytes
            )
            defaultFontFace = initializationBytes[24]
            defaultColorRgba = UInt32(initializationBytes[26]) << 24
                | UInt32(initializationBytes[27]) << 16
                | UInt32(initializationBytes[28]) << 8
                | UInt32(initializationBytes[29])
            // Invalid UTF-8 becomes replacement characters rather than failing.
            // swiftlint:disable:next optional_data_string_conversion
            let fontFamily = String(decoding: initializationBytes[43...], as: UTF8.self)
            defaultFontFamily = fontFamily == Self.tx3gSerif ? Self.serifName : Self.sansSerifName
            // font size (initializationBytes[25]) is 5% of video height
            let calculatedVideoTrackHeight = 20 * Int(initializationBytes[25])
            self.calculatedVideoTrackHeight = calculatedVideoTrackHeight
            customVerticalPlacement = (initializationBytes[0] & 0x20) != 0
            if customVerticalPlacement {
                let requestedVerticalPlacement = Int(initializationBytes[10]) << 8 | Int(initializationBytes[11])
                defaultVerticalPlacement = Self.verticalPlacement(
                    requestedVerticalPlacement,
                    calculatedVideoTrackHeight: calculatedVideoTrackHeight
                )
            } else {
                defaultVerticalPlacement = Self.defaultVerticalPlacement
            }
        } else {
            defaultFontFace = Self.defaultFontFace
            defaultColorRgba = Self.defaultColor
            defaultFontFamily = Self.defaultFontFamily
            customVerticalPlacement = false
            defaultVerticalPlacement = Self.defaultVerticalPlacement
            calculatedVideoTrackHeight = nil
        }
    }

    public func getCueReplacementBehavior() -> Format.CueReplacementBehavior {
        Self.cueReplacementBehavior
    }

    public func parse(
        data: BlockBufferReader,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws {
        var data = data
        let cueTextString = try readSubtitleText(data: &data)
        if cueTextString.isEmpty {
            try output(CuesWithTiming(cues: [], startTime: .invalid, duration: .invalid))
            return
        }

        // Attach default styles.
        var cueText = AttributedString(cueTextString)
        let fullRange = cueText.startIndex ..< cueText.endIndex
        attachFontFace(&cueText, fontFace: defaultFontFace, defaultFontFace: Self.defaultFontFace, range: fullRange)
        attachColor(&cueText, colorRgba: defaultColorRgba, defaultColorRgba: Self.defaultColor, range: fullRange)
        attachFontFamily(&cueText, fontFamily: defaultFontFamily, range: fullRange)
        var verticalPlacement = defaultVerticalPlacement

        // Find and attach additional styles. Attributes set later replace the default ones.
        while data.readableBytes >= Self.sizeAtomHeader {
            let position = data.readerIndex
            let atomSize = try Int(data.readInt(as: UInt32.self))
            let atomType = try data.readInt(as: UInt32.self)
            if atomType == Self.typeStyl {
                try checkArgument(data.readableBytes >= Self.sizeShort)
                let styleRecordCount = try data.readInt(as: UInt16.self)
                for _ in 0 ..< styleRecordCount {
                    try applyStyleRecord(data: &data, cueText: &cueText, cueTextString: cueTextString)
                }
            } else if atomType == Self.typeTbox, customVerticalPlacement, let calculatedVideoTrackHeight {
                try checkArgument(data.readableBytes >= Self.sizeShort)
                let requestedVerticalPlacement = try Int(data.readInt(as: UInt16.self))
                verticalPlacement = Self.verticalPlacement(
                    requestedVerticalPlacement,
                    calculatedVideoTrackHeight: calculatedVideoTrackHeight
                )
            }

            guard atomSize >= Self.sizeAtomHeader, position + atomSize <= data.capacity else {
                break
            }
            data.moveReaderIndex(to: position + atomSize)
        }

        let cue = Cue.Builder()
            .setText(cueText)
            .setLine(.fraction(verticalPlacement))
            .setLineAnchor(.start)
            .build()

        try output(CuesWithTiming(cues: [cue], startTime: .invalid, duration: .invalid))
    }

    private func readSubtitleText(data: inout BlockBufferReader) throws -> String {
        try checkArgument(data.readableBytes >= Self.sizeShort)
        let textLength = try Int(data.readInt(as: UInt16.self))
        if textLength == 0 {
            return ""
        }

        let textStartPosition = data.readerIndex
        let encoding = try data.readUtfCharsetFromBom()
        let bomSize = data.readerIndex - textStartPosition
        guard let text = data.readString(length: textLength - bomSize, encoding: encoding ?? .utf8) else {
            throw EndOfFileError()
        }
        return text
    }

    /// Applies a style record. Its offsets count UTF-16 code units of the text.
    private func applyStyleRecord(
        data: inout BlockBufferReader,
        cueText: inout AttributedString,
        cueTextString: String
    ) throws {
        try checkArgument(data.readableBytes >= Self.sizeStyleRecord)
        let start = try Int(data.readInt(as: UInt16.self))
        var end = try Int(data.readInt(as: UInt16.self))
        data.moveReaderIndex(forwardBy: 2) // font identifier
        let fontFace = try data.readInt(as: UInt8.self)
        data.moveReaderIndex(forwardBy: 1) // font size
        let colorRgba = try data.readInt(as: UInt32.self)

        let utf16 = cueTextString.utf16
        if end > utf16.count {
            // TODO: log "Truncating styl end (end) to cueText.length (length)."
            end = utf16.count
        }
        if start >= end {
            // TODO: log "Ignoring styl with start (start) >= end (end)."
            return
        }

        guard let range = Self.range(in: cueText, of: cueTextString, utf16Offsets: start ..< end) else {
            return
        }
        attachFontFace(&cueText, fontFace: fontFace, defaultFontFace: defaultFontFace, range: range)
        attachColor(&cueText, colorRgba: colorRgba, defaultColorRgba: defaultColorRgba, range: range)
    }

    /// The range of `text`, made of `string`, that the UTF-16 offsets cover, or `nil` if they split a character.
    private static func range(
        in text: AttributedString,
        of string: String,
        utf16Offsets offsets: Range<Int>
    ) -> Range<AttributedString.Index>? {
        let utf16 = string.utf16
        let scalars = string.unicodeScalars
        guard let start = utf16.index(utf16.startIndex, offsetBy: offsets.lowerBound, limitedBy: utf16.endIndex)?
            .samePosition(in: scalars),
            let end = utf16.index(utf16.startIndex, offsetBy: offsets.upperBound, limitedBy: utf16.endIndex)?
                .samePosition(in: scalars) else {
            return nil
        }

        let textScalars = text.unicodeScalars
        let textStart = textScalars.index(textScalars.startIndex, offsetBy: scalars.distance(from: scalars.startIndex, to: start))
        let textEnd = textScalars.index(textScalars.startIndex, offsetBy: scalars.distance(from: scalars.startIndex, to: end))
        return textStart ..< textEnd
    }

    private func attachFontFace(
        _ cueText: inout AttributedString,
        fontFace: UInt8,
        defaultFontFace: UInt8,
        range: Range<AttributedString.Index>
    ) {
        guard fontFace != defaultFontFace else { return }

        // Not bold or not italic is set too: the normal style replaces the default one.
        cueText[range].cueBold = fontFace & Self.fontFaceBold != 0
        cueText[range].cueItalic = fontFace & Self.fontFaceItalic != 0

        if fontFace & Self.fontFaceUnderline != 0 {
            cueText[range].cueUnderline = true
        }
    }

    private func attachColor(
        _ cueText: inout AttributedString,
        colorRgba: UInt32,
        defaultColorRgba: UInt32,
        range: Range<AttributedString.Index>
    ) {
        guard colorRgba != defaultColorRgba else { return }

        let color = CGColor(
            srgbRed: CGFloat((colorRgba >> 24) & 0xFF) / 255,
            green: CGFloat((colorRgba >> 16) & 0xFF) / 255,
            blue: CGFloat((colorRgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(colorRgba & 0xFF) / 255
        )
        cueText[range].cueForegroundColor = color
    }

    private func attachFontFamily(
        _ cueText: inout AttributedString,
        fontFamily: String,
        range: Range<AttributedString.Index>
    ) {
        guard fontFamily != Self.defaultFontFamily else { return }
        cueText[range].cueFontFamily = fontFamily
    }

    private static func verticalPlacement(_ requestedVerticalPlacement: Int, calculatedVideoTrackHeight: Int) -> CGFloat {
        guard calculatedVideoTrackHeight > 0 else {
            return defaultVerticalPlacement
        }
        let verticalPlacement = CGFloat(requestedVerticalPlacement) / CGFloat(calculatedVideoTrackHeight)
        return min(max(verticalPlacement, 0), 0.95)
    }
}

private extension Tx3gParser {
    static let typeStyl: UInt32 = 0x7374796c
    static let typeTbox: UInt32 = 0x74626f78
    static let tx3gSerif = "Serif"

    static let sizeAtomHeader = 8
    static let sizeShort = 2
    static let sizeStyleRecord = 12

    static let fontFaceBold: UInt8 = 0x0001
    static let fontFaceItalic: UInt8 = 0x0002
    static let fontFaceUnderline: UInt8 = 0x0004

    static let defaultFontFace: UInt8 = 0
    static let defaultColor: UInt32 = 0xFFFFFFFF
    static let serifName = "serif"
    static let sansSerifName = "sans-serif"
    static let defaultFontFamily = sansSerifName
    static let defaultVerticalPlacement: CGFloat = 0.85
}
