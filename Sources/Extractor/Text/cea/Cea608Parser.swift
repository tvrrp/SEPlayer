//
//  Cea608Parser.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.cea.Cea608Decoder
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics
import CoreMedia
import Foundation
import SEPlayerCommon

/// Parses CEA-608 closed captions (ANSI/CTA-608-E) of one channel, CC1 to CC4.
///
/// Captions are a stream of commands that build up the screen over many samples, so the parser keeps its state from
/// one sample to the next. It emits the cues on screen each time they change; each set replaces the one before, and
/// goes away by itself if nothing replaces it for `validDataChannelTimeout`, as when the captions stop.
///
/// Supports pop-on, roll-up and paint-on captions, the basic, special and extended character sets, preamble address
/// codes, mid-row styles (colors, italics, underline) and tab offsets.
public final class Cea608Parser: SubtitleParser {
    public static let cueReplacementBehavior: CueReplacementBehavior = .replace
    /// How long cues stay on screen without any change.
    public static let validDataChannelTimeout = CMTime(value: 16, timescale: 1)

    /// The bytes of a packet: `cc_valid`, `cc_type` and two bytes of data in transport streams; only the data in MP4.
    private let packetLength: Int
    private let selectedField: UInt8
    private let selectedChannel: UInt8

    private var cueBuilders: [CueBuilder] = []
    private var currentCueBuilder: CueBuilder
    /// The cues on screen.
    private var cues: [Cue] = []
    /// The cues last emitted.
    private var emittedCues: [Cue] = []

    private var captionMode = CaptionMode.unknown
    private var captionRowCount = Cea608Parser.defaultCaptionRowCount
    private var isCaptionValid = false
    private var repeatableControl: (cc1: UInt8, cc2: UInt8)?
    private var currentChannel: UInt8 = 0
    /// Whether the data is captions rather than text or extended data services.
    private var isInCaptionService = true

    /// - Parameter channel: 1 to 4 for CC1 to CC4; anything else is CC1.
    public init(mimeType: MimeTypes, channel: Int?) {
        packetLength = mimeType == .applicationMP4CEA608 ? 2 : 3
        switch channel {
        case 2: (selectedChannel, selectedField) = (1, 0)
        case 3: (selectedChannel, selectedField) = (0, 1)
        case 4: (selectedChannel, selectedField) = (1, 1)
        default: (selectedChannel, selectedField) = (0, 0)
        }
        currentCueBuilder = CueBuilder(captionMode: .unknown, captionRowCount: Self.defaultCaptionRowCount)
        cueBuilders = [currentCueBuilder]
    }

    public func getCueReplacementBehavior() -> CueReplacementBehavior {
        Self.cueReplacementBehavior
    }

    public func reset() {
        cues = []
        emittedCues = []
        captionMode = .unknown
        captionRowCount = Self.defaultCaptionRowCount
        resetCueBuilders()
        isCaptionValid = false
        repeatableControl = nil
        currentChannel = 0
        isInCaptionService = true
    }

    public func parse(
        data: BlockBufferReader,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws {
        let bytes = data.readableBytesView
        var index = bytes.startIndex
        var captionDataProcessed = false

        while bytes.endIndex - index >= packetLength {
            let header: UInt8
            if packetLength == 2 {
                header = Self.implicitDataHeader
            } else {
                header = bytes[index]
                index += 1
            }
            let byte1 = bytes[index]
            let byte2 = bytes[index + 1]
            index += 2

            // CEA-708 data, or the other field.
            guard header & Self.ccTypeFlag == 0, header & Self.ccFieldFlag == selectedField else {
                continue
            }

            // The parity bit is not part of the data.
            let cc1 = byte1 & 0x7F
            let cc2 = byte2 & 0x7F
            // Padding.
            if cc1 == 0, cc2 == 0 { continue }

            let wasCaptionValid = isCaptionValid
            isCaptionValid = header & Self.ccValidFlag != 0 && Self.hasOddParity(byte1) && Self.hasOddParity(byte2)
            if isRepeatedCommand(cc1, cc2) {
                // Commands come twice in a row, in case one is lost.
                continue
            }
            guard isCaptionValid else {
                if wasCaptionValid {
                    // The encoder turned the validity off: the captions are off.
                    resetCueBuilders()
                    captionDataProcessed = true
                }
                continue
            }

            updateIsInCaptionService(cc1, cc2)
            guard isInCaptionService, updateAndVerifyCurrentChannel(cc1) else {
                continue
            }

            if Self.isControlCode(cc1) {
                if Self.isSpecialNorthAmericanChar(cc1, cc2) {
                    currentCueBuilder.append(Self.specialCharacter(cc2))
                } else if Self.isExtendedWestEuropeanChar(cc1, cc2) {
                    // The character replaces its standard equivalent, sent before it.
                    currentCueBuilder.backspace()
                    currentCueBuilder.append(Self.extendedWestEuropeanCharacter(cc1, cc2))
                } else if Self.isMidRowControlCode(cc1, cc2) {
                    handleMidRowControl(cc2)
                } else if Self.isPreambleAddressCode(cc1, cc2) {
                    handlePreambleAddressCode(cc1, cc2)
                } else if Self.isTabControlCode(cc1, cc2) {
                    currentCueBuilder.tabOffset = Int(cc2) - 0x20
                } else if Self.isMiscCode(cc1, cc2) {
                    handleMiscCode(cc2)
                }
            } else {
                currentCueBuilder.append(Self.basicCharacter(cc1))
                if cc2 & 0xE0 != 0 {
                    currentCueBuilder.append(Self.basicCharacter(cc2))
                }
            }
            captionDataProcessed = true
        }

        if captionDataProcessed, captionMode == .rollUp || captionMode == .paintOn {
            cues = displayCues()
        }
        if cues != emittedCues {
            emittedCues = cues
            try output(CuesWithTiming(cues: cues, startTime: .invalid, duration: Self.validDataChannelTimeout))
        }
    }

    // MARK: - Commands

    /// Whether this is the second of a repeated command. A third one counts again.
    private func isRepeatedCommand(_ cc1: UInt8, _ cc2: UInt8) -> Bool {
        guard isCaptionValid, Self.isRepeatable(cc1) else {
            repeatableControl = nil
            return false
        }
        if let repeatableControl, repeatableControl == (cc1, cc2) {
            self.repeatableControl = nil
            return true
        }
        repeatableControl = (cc1, cc2)
        return false
    }

    private func updateIsInCaptionService(_ cc1: UInt8, _ cc2: UInt8) {
        if Self.isXdsControlCode(cc1) {
            isInCaptionService = false
        } else if Self.isServiceSwitchCommand(cc1) {
            switch cc2 {
            case Command.textRestart,
                 Command.resumeTextDisplay:
                isInCaptionService = false
            case Command.endOfCaption,
                 Command.resumeCaptionLoading,
                 Command.resumeDirectCaptioning,
                 Command.rollUp2Rows,
                 Command.rollUp3Rows,
                 Command.rollUp4Rows:
                isInCaptionService = true
            default:
                break
            }
        }
    }

    private func updateAndVerifyCurrentChannel(_ cc1: UInt8) -> Bool {
        if Self.isControlCode(cc1) {
            currentChannel = (cc1 >> 3) & 0x1
        }
        return currentChannel == selectedChannel
    }

    private func handleMidRowControl(_ cc2: UInt8) {
        // A mid-row code takes the place of a space.
        currentCueBuilder.append(" ")
        // cc2: 0|0|1|0|STYLE|U
        currentCueBuilder.setStyle(Int((cc2 >> 1) & 0x07), underline: cc2 & 0x01 != 0)
    }

    private func handlePreambleAddressCode(_ cc1: UInt8, _ cc2: UInt8) {
        // cc1: 0|0|0|1|C|E|ROW
        var row = Self.rowIndices[Int(cc1 & 0x07)]
        // cc2: 0|1|N|ATTRIBUTE|U, where N moves one row down.
        if cc2 & 0x20 != 0 {
            row += 1
        }
        if row != currentCueBuilder.row {
            if captionMode != .rollUp, !currentCueBuilder.isEmpty {
                currentCueBuilder = CueBuilder(captionMode: captionMode, captionRowCount: captionRowCount)
                cueBuilders.append(currentCueBuilder)
            }
            currentCueBuilder.row = row
        }

        // cc2: 0|1|N|0|STYLE|U, or 0|1|N|1|CURSOR|U
        let isCursor = cc2 & 0x10 != 0
        let cursorOrStyle = Int((cc2 >> 1) & 0x07)
        // Also for a cursor: the underline bit counts.
        currentCueBuilder.setStyle(isCursor ? Self.styleUnchanged : cursorOrStyle, underline: cc2 & 0x01 != 0)
        if isCursor {
            currentCueBuilder.indent = Self.columnIndices[cursorOrStyle]
        }
    }

    private func handleMiscCode(_ cc2: UInt8) {
        switch cc2 {
        case Command.rollUp2Rows:
            setCaptionMode(.rollUp)
            setCaptionRowCount(2)
            return
        case Command.rollUp3Rows:
            setCaptionMode(.rollUp)
            setCaptionRowCount(3)
            return
        case Command.rollUp4Rows:
            setCaptionMode(.rollUp)
            setCaptionRowCount(4)
            return
        case Command.resumeCaptionLoading:
            setCaptionMode(.popOn)
            return
        case Command.resumeDirectCaptioning:
            setCaptionMode(.paintOn)
            return
        default:
            break
        }

        guard captionMode != .unknown else { return }
        switch cc2 {
        case Command.eraseDisplayedMemory:
            cues = []
            if captionMode == .rollUp || captionMode == .paintOn {
                resetCueBuilders()
            }
        case Command.eraseNonDisplayedMemory:
            resetCueBuilders()
        case Command.endOfCaption:
            cues = displayCues()
            resetCueBuilders()
        case Command.carriageReturn:
            // Only roll-up captions move up, and only with something to move.
            if captionMode == .rollUp, !currentCueBuilder.isEmpty {
                currentCueBuilder.rollUp()
            }
        case Command.backspace:
            currentCueBuilder.backspace()
        default:
            break
        }
    }

    private func setCaptionMode(_ captionMode: CaptionMode) {
        guard self.captionMode != captionMode else { return }
        let oldCaptionMode = self.captionMode
        self.captionMode = captionMode

        if captionMode == .paintOn {
            // Selecting paint-on changes nothing else.
            cueBuilders.forEach { $0.captionMode = captionMode }
            return
        }

        resetCueBuilders()
        if oldCaptionMode == .paintOn || captionMode == .rollUp || captionMode == .unknown {
            // Leaving paint-on, or going to roll-up, clears the screen too.
            cues = []
        }
    }

    private func setCaptionRowCount(_ captionRowCount: Int) {
        self.captionRowCount = captionRowCount
        currentCueBuilder.captionRowCount = captionRowCount
    }

    private func resetCueBuilders() {
        currentCueBuilder.reset(captionMode: captionMode)
        cueBuilders = [currentCueBuilder]
    }

    /// The cues of the rows built so far.
    ///
    /// CEA-608 has no alignment, but captions are centered or aligned to the end with spaces. Each row guesses its
    /// alignment from them; all rows then take the first of start, middle and end that one of them has, so that rows
    /// of one caption line up.
    private func displayCues() -> [Cue] {
        let built = cueBuilders.map { $0.build(forcedPositionAnchor: nil) }
        let positionAnchor = built.compactMap { $0?.positionAnchor }.min { $0.rawValue < $1.rawValue } ?? .end
        return zip(cueBuilders, built).compactMap { builder, cue in
            guard let cue else { return nil }
            return cue.positionAnchor == positionAnchor ? cue : builder.build(forcedPositionAnchor: positionAnchor)
        }
    }

    // MARK: - Codes

    private static let defaultCaptionRowCount = 4
    /// The header of MP4 samples, which carry the data alone: valid, NTSC field 1.
    private static let implicitDataHeader: UInt8 = 0xFC
    private static let ccValidFlag: UInt8 = 0x04
    /// Set for CEA-708 data.
    private static let ccTypeFlag: UInt8 = 0x02
    private static let ccFieldFlag: UInt8 = 0x01

    /// The row of each preamble address code, from 1 at the top to 15 at the bottom.
    private static let rowIndices = [11, 1, 3, 12, 14, 5, 7, 9]
    private static let columnIndices = [0, 4, 8, 12, 16, 20, 24, 28]
    fileprivate static let styleItalics = 0x07
    fileprivate static let styleUnchanged = 0x08

    private enum Command {
        static let resumeCaptionLoading: UInt8 = 0x20
        static let backspace: UInt8 = 0x21
        static let deleteToEndOfRow: UInt8 = 0x24
        static let rollUp2Rows: UInt8 = 0x25
        static let rollUp3Rows: UInt8 = 0x26
        static let rollUp4Rows: UInt8 = 0x27
        static let resumeDirectCaptioning: UInt8 = 0x29
        static let textRestart: UInt8 = 0x2A
        static let resumeTextDisplay: UInt8 = 0x2B
        static let eraseDisplayedMemory: UInt8 = 0x2C
        static let carriageReturn: UInt8 = 0x2D
        static let eraseNonDisplayedMemory: UInt8 = 0x2E
        static let endOfCaption: UInt8 = 0x2F
    }

    fileprivate enum CaptionMode {
        case unknown
        case rollUp
        case popOn
        case paintOn
    }

    private static func hasOddParity(_ byte: UInt8) -> Bool {
        byte.nonzeroBitCount % 2 == 1
    }

    /// cc1: 0|0|0|X|X|X|X|X
    private static func isControlCode(_ cc1: UInt8) -> Bool { cc1 & 0xE0 == 0 }
    private static func isRepeatable(_ cc1: UInt8) -> Bool { cc1 & 0xF0 == 0x10 }
    private static func isXdsControlCode(_ cc1: UInt8) -> Bool { (0x01 ... 0x0F).contains(cc1) }
    /// cc1: 0|0|0|1|C|1|0|0
    private static func isServiceSwitchCommand(_ cc1: UInt8) -> Bool { cc1 & 0xF7 == 0x14 }
    /// cc1: 0|0|0|1|C|0|0|1, cc2: 0|0|1|1|X|X|X|X
    private static func isSpecialNorthAmericanChar(_ cc1: UInt8, _ cc2: UInt8) -> Bool {
        cc1 & 0xF7 == 0x11 && cc2 & 0xF0 == 0x30
    }

    /// cc1: 0|0|0|1|C|0|1|S, cc2: 0|0|1|X|X|X|X|X
    private static func isExtendedWestEuropeanChar(_ cc1: UInt8, _ cc2: UInt8) -> Bool {
        cc1 & 0xF6 == 0x12 && cc2 & 0xE0 == 0x20
    }

    /// cc1: 0|0|0|1|C|0|0|1, cc2: 0|0|1|0|X|X|X|X
    private static func isMidRowControlCode(_ cc1: UInt8, _ cc2: UInt8) -> Bool {
        cc1 & 0xF7 == 0x11 && cc2 & 0xF0 == 0x20
    }

    /// cc1: 0|0|0|1|C|X|X|X, cc2: 0|1|X|X|X|X|X|X
    private static func isPreambleAddressCode(_ cc1: UInt8, _ cc2: UInt8) -> Bool {
        cc1 & 0xF0 == 0x10 && cc2 & 0xC0 == 0x40
    }

    /// cc1: 0|0|0|1|C|1|1|1, cc2: 0x21 to 0x23
    private static func isTabControlCode(_ cc1: UInt8, _ cc2: UInt8) -> Bool {
        cc1 & 0xF7 == 0x17 && (0x21 ... 0x23).contains(cc2)
    }

    /// cc1: 0|0|0|1|C|1|0|F, cc2: 0|0|1|0|X|X|X|X
    private static func isMiscCode(_ cc1: UInt8, _ cc2: UInt8) -> Bool {
        cc1 & 0xF6 == 0x14 && cc2 & 0xF0 == 0x20
    }

    private static func basicCharacter(_ cc: UInt8) -> Character {
        character(basicCharacterSet[Int(cc & 0x7F) - 0x20])
    }

    private static func specialCharacter(_ cc2: UInt8) -> Character {
        character(specialCharacterSet[Int(cc2 & 0x0F)])
    }

    private static func extendedWestEuropeanCharacter(_ cc1: UInt8, _ cc2: UInt8) -> Character {
        let set = cc1 & 0x01 == 0 ? spanishFrenchCharacterSet : portugueseGermanCharacterSet
        return character(set[Int(cc2 & 0x1F)])
    }

    private static func character(_ code: UInt32) -> Character {
        Character(Unicode.Scalar(code) ?? " ")
    }

    /// From 0x20: ASCII, except for a few accented letters and symbols.
    private static let basicCharacterSet: [UInt32] = [
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29,
        0xE1, // 2A: á
        0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
        0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
        0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B,
        0xE9, // 5C: é
        0x5D,
        0xED, // 5E: í
        0xF3, // 5F: ó
        0xFA, // 60: ú
        0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
        0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A,
        0xE7, // 7B: ç
        0xF7, // 7C: ÷
        0xD1, // 7D: Ñ
        0xF1, // 7E: ñ
        0x25A0, // 7F: ■
    ]

    /// From 0x30.
    private static let specialCharacterSet: [UInt32] = [
        0xAE, 0xB0, 0xBD, 0xBF, 0x2122, 0xA2, 0xA3, 0x266A,
        0xE0, 0x20, // 39: transparent space
        0xE8, 0xE2, 0xEA, 0xEE, 0xF4, 0xFB,
    ]

    /// From 0x20: Spanish and miscellaneous, then French.
    private static let spanishFrenchCharacterSet: [UInt32] = [
        0xC1, 0xC9, 0xD3, 0xDA, 0xDC, 0xFC, 0x2018, 0xA1,
        0x2A, 0x27, 0x2014, 0xA9, 0x2120, 0x2022, 0x201C, 0x201D,
        0xC0, 0xC2, 0xC7, 0xC8, 0xCA, 0xCB, 0xEB, 0xCE,
        0xCF, 0xEF, 0xD4, 0xD9, 0xF9, 0xDB, 0xAB, 0xBB,
    ]

    /// From 0x20: Portuguese, then German and Danish.
    private static let portugueseGermanCharacterSet: [UInt32] = [
        0xC3, 0xE3, 0xCD, 0xCC, 0xEC, 0xD2, 0xF2, 0xD5,
        0xF5, 0x7B, 0x7D, 0x5C, 0x5E, 0x5F, 0x7C, 0x7E,
        0xC4, 0xE4, 0xD6, 0xF6, 0xDF, 0xA5, 0xA4, 0x2502,
        0xC5, 0xE5, 0xD8, 0xF8, 0x250C, 0x2510, 0x2514, 0x2518,
    ]
}

/// The text of one caption row, or of the rows rolled up above it, with its styles and place on the 32 by 15 grid.
private final class CueBuilder {
    private static let screenCharacterWidth = 32
    private static let baseRow = 15
    private static let styleColors: [CGColor] = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        CGColor(red: 0, green: 1, blue: 0, alpha: 1),
        CGColor(red: 0, green: 0, blue: 1, alpha: 1),
        CGColor(red: 0, green: 1, blue: 1, alpha: 1),
        CGColor(red: 1, green: 0, blue: 0, alpha: 1),
        CGColor(red: 1, green: 1, blue: 0, alpha: 1),
        CGColor(red: 1, green: 0, blue: 1, alpha: 1),
    ]

    /// A style that starts at `start` in the current row.
    private struct Style {
        let style: Int
        let underline: Bool
        var start: Int
    }

    var row = CueBuilder.baseRow
    var indent = 0
    var tabOffset = 0
    var captionMode: Cea608Parser.CaptionMode
    var captionRowCount: Int

    private var styles: [Style] = []
    private var rolledUpCaptions: [AttributedString] = []
    private var text: [Character] = []

    init(captionMode: Cea608Parser.CaptionMode, captionRowCount: Int) {
        self.captionMode = captionMode
        self.captionRowCount = captionRowCount
    }

    var isEmpty: Bool {
        styles.isEmpty && rolledUpCaptions.isEmpty && text.isEmpty
    }

    func reset(captionMode: Cea608Parser.CaptionMode) {
        self.captionMode = captionMode
        styles.removeAll()
        rolledUpCaptions.removeAll()
        text.removeAll()
        row = Self.baseRow
        indent = 0
        tabOffset = 0
    }

    func setStyle(_ style: Int, underline: Bool) {
        styles.append(Style(style: style, underline: underline, start: text.count))
    }

    func backspace() {
        guard !text.isEmpty else { return }
        let length = text.count
        text.removeLast()
        // Styles that started at the removed character start where it was.
        for index in styles.indices.reversed() {
            guard styles[index].start == length else { break }
            styles[index].start -= 1
        }
    }

    func append(_ character: Character) {
        // The row is no wider than the screen; indent and tab offset trim it further when built.
        if text.count < Self.screenCharacterWidth {
            text.append(character)
        }
    }

    func rollUp() {
        rolledUpCaptions.append(currentLine())
        text.removeAll()
        styles.removeAll()
        let rowCount = min(captionRowCount, row)
        while rolledUpCaptions.count >= rowCount, !rolledUpCaptions.isEmpty {
            rolledUpCaptions.removeFirst()
        }
    }

    /// The cue, or `nil` if there is no text.
    ///
    /// - Parameter forcedPositionAnchor: The alignment to take, rather than guess it from the spaces around the text.
    func build(forcedPositionAnchor: Cue.Anchor?) -> Cue? {
        // Empty columns before the text, from 0 to 31.
        let startPadding = indent + tabOffset
        let maxTextLength = Self.screenCharacterWidth - startPadding

        var cueText = AttributedString()
        for caption in rolledUpCaptions {
            cueText.append(Self.truncated(caption, to: maxTextLength))
            cueText.append(AttributedString("\n"))
        }
        cueText.append(Self.truncated(currentLine(), to: maxTextLength))
        let length = cueText.characters.count
        guard length > 0 else { return nil }

        // Empty columns after the text.
        let endPadding = Self.screenCharacterWidth - startPadding - length
        let paddingDelta = startPadding - endPadding
        let positionAnchor: Cue.Anchor = if let forcedPositionAnchor {
            forcedPositionAnchor
        } else if captionMode == .popOn, abs(paddingDelta) < 3 || endPadding < 0 {
            // About centered, or wider than the screen.
            .middle
        } else if captionMode == .popOn, paddingDelta > 0 {
            .end
        } else {
            .start
        }

        let position: CGFloat = switch positionAnchor {
        case .middle:
            0.5
        case .end:
            // Within the 80% of the width safe to show text in.
            CGFloat(Self.screenCharacterWidth - endPadding) / CGFloat(Self.screenCharacterWidth) * 0.8 + 0.1
        case .start:
            CGFloat(startPadding) / CGFloat(Self.screenCharacterWidth) * 0.8 + 0.1
        }

        // Rows count from 1 at the top; lines from 0 at the top, and from -1 at the bottom. A blank row on each side
        // keeps the text in the safe area.
        let line: Int
        let lineAnchor: Cue.Anchor
        if row > Self.baseRow / 2 {
            line = row - Self.baseRow - 2
            lineAnchor = .end
        } else {
            line = row
            lineAnchor = .start
        }

        return Cue.Builder()
            .setText(cueText)
            .setTextAlignment(.leading)
            .setLine(.number(line))
            .setLineAnchor(lineAnchor)
            .setPosition(position)
            .setPositionAnchor(positionAnchor)
            .build()
    }

    /// The current row with its styles: a color clears italics, italics keep the color, and white is no color.
    private func currentLine() -> AttributedString {
        var line = AttributedString()
        var italic = false
        var underline = false
        var color = 0
        var styleIndex = 0
        var run = ""
        var runAttributes = AttributeContainer()

        func attributes() -> AttributeContainer {
            var container = AttributeContainer()
            if italic { container[CueTextAttributes.ItalicAttribute.self] = true }
            if underline { container[CueTextAttributes.UnderlineAttribute.self] = true }
            if color != 0 { container[CueTextAttributes.ForegroundColorAttribute.self] = Self.styleColors[color] }
            return container
        }

        for (position, character) in text.enumerated() {
            while styleIndex < styles.count, styles[styleIndex].start <= position {
                let style = styles[styleIndex]
                if style.style != Cea608Parser.styleUnchanged {
                    italic = style.style == Cea608Parser.styleItalics
                    if style.style != Cea608Parser.styleItalics { color = style.style }
                }
                underline = style.underline
                styleIndex += 1
            }
            let current = attributes()
            if current != runAttributes, !run.isEmpty {
                line.append(AttributedString(run, attributes: runAttributes))
                run = ""
            }
            runAttributes = current
            run.append(character)
        }
        if !run.isEmpty {
            line.append(AttributedString(run, attributes: runAttributes))
        }
        return line
    }

    private static func truncated(_ text: AttributedString, to length: Int) -> AttributedString {
        guard text.characters.count > length else { return text }
        let end = text.characters.index(text.startIndex, offsetBy: max(0, length))
        return AttributedString(text[text.startIndex ..< end])
    }
}
