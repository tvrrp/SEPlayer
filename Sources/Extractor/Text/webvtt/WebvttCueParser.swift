//
//  WebvttCueParser.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.webvtt.WebvttCueParser
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics
import CoreMedia
import Foundation
import SEPlayerCommon

/// A cue of a WebVTT file, with its times.
struct WebvttCueInfo {
    let cue: Cue
    let startTime: CMTime
    let endTime: CMTime
}

/// Parses the cues of a WebVTT file: their timing line, settings and text with its markup.
enum WebvttCueParser {
    /// The timing line of a cue: `start --> end settings`.
    struct CueHeader {
        let startTimestamp: Substring
        let endTimestamp: Substring
        let settings: Substring

        init?(line: String) {
            // ^(\S+)\s+-->\s+(\S+)(.*)?$
            guard let arrow = line.range(of: "-->") else { return nil }
            let before = line[..<arrow.lowerBound]
            let after = line[arrow.upperBound...]
            guard let lastBefore = before.last, lastBefore.isWhitespace,
                  let firstAfter = after.first, firstAfter.isWhitespace else {
                return nil
            }
            let start = before.trimmingCharacters(in: .whitespaces)
            guard !start.isEmpty, !start.contains(where: \.isWhitespace) else {
                return nil
            }
            let afterTrimmed = after.drop(while: \.isWhitespace)
            let end = afterTrimmed.prefix { !$0.isWhitespace }
            guard !end.isEmpty else { return nil }
            startTimestamp = Substring(start)
            endTimestamp = end
            settings = afterTrimmed.dropFirst(end.count)
        }
    }

    /// Reads a cue: an optional id line, the timing line and the text lines up to an empty line.
    ///
    /// - Returns: The cue, or `nil` if the lines are not a valid cue.
    static func parseCue(_ reader: inout WebvttLineReader, styles: [WebvttCssStyle]) -> WebvttCueInfo? {
        guard let firstLine = reader.readLine() else { return nil }
        if let header = CueHeader(line: firstLine) {
            return parseCue(id: nil, header: header, reader: &reader, styles: styles)
        }
        // The first line is the id of the cue.
        guard let secondLine = reader.readLine(), let header = CueHeader(line: secondLine) else {
            return nil
        }
        return parseCue(id: firstLine.trimmingCharacters(in: .whitespaces), header: header, reader: &reader, styles: styles)
    }

    /// Parses the cue settings, `name:value` pairs separated by whitespace, into a cue with default text.
    static func parseCueSettings(_ settings: some StringProtocol) -> Cue {
        var builder = WebvttCueInfoBuilder()
        parseCueSettingsList(Substring(settings), builder: &builder)
        return builder.toCueBuilder().build()
    }

    /// Parses the text of a cue, with its markup and styles.
    static func parseCueText(id: String?, markup: String, styles: [WebvttCssStyle]) -> AttributedString {
        var text = AttributedString()
        var startTagStack: [StartTag] = []
        var nestedElements: [Element] = []
        let characters = Array(markup)
        var position = 0

        while position < characters.count {
            let character = characters[position]
            switch character {
            case .tagStart:
                guard position + 1 < characters.count else {
                    position += 1
                    break
                }
                let ltPosition = position
                let isClosingTag = characters[ltPosition + 1] == "/"
                position = findEndOfTag(characters, startPosition: ltPosition + 1)
                let isVoidTag = position >= 2 && characters[position - 2] == "/"
                let expressionStart = ltPosition + (isClosingTag ? 2 : 1)
                let expressionEnd = isVoidTag ? position - 2 : (characters[position - 1] == .tagEnd ? position - 1 : position)
                guard expressionStart < expressionEnd else { continue }
                let fullTagExpression = String(characters[expressionStart ..< expressionEnd])
                guard !fullTagExpression.trimmingCharacters(in: .whitespaces).isEmpty else {
                    continue
                }
                let tagName = getTagName(fullTagExpression)
                guard isSupportedTag(tagName) else { continue }

                if isClosingTag {
                    while let startTag = startTagStack.popLast() {
                        applySpansForTag(cueId: id, startTag: startTag, nestedElements: nestedElements, text: &text, styles: styles)
                        if !startTagStack.isEmpty {
                            nestedElements.append(Element(startTag: startTag, endPosition: text.unicodeScalars.count))
                        } else {
                            nestedElements.removeAll()
                        }
                        if startTag.name == tagName { break }
                    }
                } else if !isVoidTag {
                    startTagStack.append(StartTag(fullTagExpression: fullTagExpression, position: text.unicodeScalars.count))
                }
            case .entityStart:
                let semicolonEndIndex = characters[(position + 1)...].firstIndex(of: ";")
                let spaceEndIndex = characters[(position + 1)...].firstIndex(of: " ")
                let entityEndIndex: Int? = switch (semicolonEndIndex, spaceEndIndex) {
                case let (semicolon?, space?): min(semicolon, space)
                case let (semicolon?, nil): semicolon
                case let (nil, space?): space
                case (nil, nil): nil
                }
                if let entityEndIndex {
                    applyEntity(String(characters[(position + 1) ..< entityEndIndex]), to: &text)
                    if entityEndIndex == spaceEndIndex {
                        text.append(AttributedString(" "))
                    }
                    position = entityEndIndex + 1
                } else {
                    text.append(AttributedString(String(character)))
                    position += 1
                }
            default:
                text.append(AttributedString(String(character)))
                position += 1
            }
        }

        // Unclosed tags apply to the end of the cue.
        while let startTag = startTagStack.popLast() {
            applySpansForTag(cueId: id, startTag: startTag, nestedElements: nestedElements, text: &text, styles: styles)
        }
        applySpansForTag(cueId: id, startTag: .wholeCue, nestedElements: [], text: &text, styles: styles)
        return text
    }

    /// The range of `text` between two Unicode scalar offsets, the positions the parser keeps.
    private static func range(of text: AttributedString, from start: Int, to end: Int) -> Range<AttributedString.Index> {
        let scalars = text.unicodeScalars
        let lowerBound = scalars.index(scalars.startIndex, offsetBy: start)
        return lowerBound ..< scalars.index(lowerBound, offsetBy: max(0, end - start))
    }

    // MARK: - Cues

    private static func parseCue(
        id: String?,
        header: CueHeader,
        reader: inout WebvttLineReader,
        styles: [WebvttCssStyle]
    ) -> WebvttCueInfo? {
        var builder = WebvttCueInfoBuilder()
        do {
            builder.startTime = try WebvttParserUtil.parseTimestamp(header.startTimestamp)
            builder.endTime = try WebvttParserUtil.parseTimestamp(header.endTimestamp)
        } catch {
            // A cue with bad times is skipped.
            return nil
        }
        parseCueSettingsList(header.settings, builder: &builder)

        var textLines: [String] = []
        while let line = reader.readLine(), !line.isEmpty {
            textLines.append(line.trimmingCharacters(in: .whitespaces))
        }
        builder.text = parseCueText(id: id, markup: textLines.joined(separator: "\n"), styles: styles)
        return builder.build()
    }

    private static func parseCueSettingsList(_ settings: Substring, builder: inout WebvttCueInfoBuilder) {
        // (\S+?):(\S+)
        for setting in settings.split(whereSeparator: \.isWhitespace) {
            guard let colon = setting.firstIndex(of: ":"), colon != setting.startIndex else {
                continue
            }
            let name = setting[..<colon]
            let value = setting[setting.index(after: colon)...]
            guard !value.isEmpty else { continue }
            do {
                switch name {
                case "line":
                    try parseLineAttribute(value, builder: &builder)
                case "align":
                    builder.textAlignment = parseTextAlignment(value)
                case "position":
                    try parsePositionAttribute(value, builder: &builder)
                case "size":
                    builder.size = try WebvttParserUtil.parsePercentage(value)
                case "vertical":
                    builder.verticalType = parseVerticalAttribute(value)
                default:
                    // Region and unknown settings are ignored.
                    break
                }
            } catch {
                // A bad setting is ignored.
                continue
            }
        }
    }

    private static func parseLineAttribute(_ string: Substring, builder: inout WebvttCueInfoBuilder) throws {
        var string = string
        if let commaIndex = string.firstIndex(of: ",") {
            builder.lineAnchor = parseAnchor(string[string.index(after: commaIndex)...], isLine: true)
            string = string[..<commaIndex]
        }
        if string.hasSuffix("%") {
            builder.line = try WebvttParserUtil.parsePercentage(string)
            builder.snapToLines = false
        } else {
            guard let lineNumber = Int(string) else {
                throw ParserError.createForMalformedDataOfUnknownType(message: "Invalid line: \(string)")
            }
            // Line numbers count from the top when positive, and from the bottom when negative.
            builder.line = CGFloat(lineNumber)
            builder.snapToLines = true
        }
    }

    private static func parsePositionAttribute(_ string: Substring, builder: inout WebvttCueInfoBuilder) throws {
        var string = string
        if let commaIndex = string.firstIndex(of: ",") {
            builder.positionAnchor = parseAnchor(string[string.index(after: commaIndex)...], isLine: false)
            string = string[..<commaIndex]
        }
        builder.position = try WebvttParserUtil.parsePercentage(string)
    }

    private static func parseAnchor(_ string: Substring, isLine: Bool) -> Cue.Anchor? {
        switch string {
        case "start": .start
        case "line-left" where !isLine: .start
        case "center",
             "middle": .middle
        case "end": .end
        case "line-right" where !isLine: .end
        default: nil
        }
    }

    private static func parseVerticalAttribute(_ string: Substring) -> Cue.VerticalType? {
        switch string {
        case "rl": .rightToLeft
        case "lr": .leftToRight
        default: nil
        }
    }

    private static func parseTextAlignment(_ string: Substring) -> WebvttCueInfoBuilder.TextAlignment {
        switch string {
        case "start": .start
        case "left": .left
        case "center",
             "middle": .center
        case "end": .end
        case "right": .right
        default: .center
        }
    }

    // MARK: - Markup

    private static func findEndOfTag(_ characters: [Character], startPosition: Int) -> Int {
        guard startPosition < characters.count,
              let index = characters[startPosition...].firstIndex(of: .tagEnd) else {
            return characters.count
        }
        return index + 1
    }

    private static func applyEntity(_ entity: String, to text: inout AttributedString) {
        let replacement: String? = switch entity {
        case "lt": "<"
        case "gt": ">"
        case "nbsp": " "
        case "amp": "&"
        default: nil
        }
        // Unsupported entities are dropped.
        if let replacement {
            text.append(AttributedString(replacement))
        }
    }

    private static func isSupportedTag(_ tagName: String) -> Bool {
        switch tagName {
        case .tagBold,
             .tagClass,
             .tagItalic,
             .tagLang,
             .tagRuby,
             .tagRubyText,
             .tagUnderline,
             .tagVoice: true
        default: false
        }
    }

    private static func getTagName(_ tagExpression: String) -> String {
        let trimmed = tagExpression.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix { $0 != " " && $0 != "." })
    }

    private static func applySpansForTag(
        cueId: String?,
        startTag: StartTag,
        nestedElements: [Element],
        text: inout AttributedString,
        styles: [WebvttCssStyle]
    ) {
        let start = startTag.position
        let range = Self.range(of: text, from: start, to: text.unicodeScalars.count)

        switch startTag.name {
        case .tagBold:
            text[range].cueBold = true
        case .tagItalic:
            text[range].cueItalic = true
        case .tagRuby:
            applyRubySpans(text: &text, cueId: cueId, rubyTag: startTag, nestedElements: nestedElements, styles: styles)
        case .tagUnderline:
            text[range].cueUnderline = true
        case .tagClass:
            applyDefaultColors(text: &text, classes: startTag.classes, range: range)
        case .tagVoice:
            if !startTag.voice.isEmpty {
                text[range].cueVoice = startTag.voice
            }
        case .tagLang,
             "":
            break
        default:
            return
        }

        // The ruby text moved out of the text: the range may be shorter now.
        let styledRange = Self.range(of: text, from: start, to: text.unicodeScalars.count)
        for style in applicableStyles(styles, cueId: cueId, tag: startTag) {
            applyStyle(style, to: &text, range: styledRange)
        }
    }

    /// Moves the text of each `<rt>` element into a ruby annotation over the base text before it.
    private static func applyRubySpans(
        text: inout AttributedString,
        cueId: String?,
        rubyTag: StartTag,
        nestedElements: [Element],
        styles: [WebvttCssStyle]
    ) {
        let rubyTagPosition = rubyPosition(styles, cueId: cueId, tag: rubyTag)
        var deletedCharacterCount = 0
        var lastRubyTextEnd = rubyTag.position
        for element in nestedElements.sorted(by: { $0.startTag.position < $1.startTag.position }) {
            guard element.startTag.name == .tagRubyText else { continue }
            // The <rt> element's position, else the <ruby> element's, else over the text.
            let position = rubyPosition(styles, cueId: cueId, tag: element.startTag) ?? rubyTagPosition ?? .before
            let rubyTextStart = element.startTag.position - deletedCharacterCount
            let rubyTextEnd = element.endPosition - deletedCharacterCount
            guard rubyTextStart >= lastRubyTextEnd,
                  rubyTextEnd <= text.unicodeScalars.count,
                  rubyTextStart <= rubyTextEnd else {
                continue
            }

            let rubyTextRange = range(of: text, from: rubyTextStart, to: rubyTextEnd)
            let rubyText = String(text[rubyTextRange].characters)
            text.removeSubrange(rubyTextRange)
            if rubyTextStart > lastRubyTextEnd {
                text[range(of: text, from: lastRubyTextEnd, to: rubyTextStart)].cueRuby = Cue.Ruby(
                    text: rubyText,
                    position: position
                )
            }
            deletedCharacterCount += rubyText.unicodeScalars.count
            // The ruby text is gone, so its start is where the next base text starts.
            lastRubyTextEnd = rubyTextStart
        }
    }

    private static func rubyPosition(_ styles: [WebvttCssStyle], cueId: String?, tag: StartTag) -> Cue.AnnotationPosition? {
        applicableStyles(styles, cueId: cueId, tag: tag).lazy.compactMap(\.rubyPosition).first
    }

    private static func applyDefaultColors(
        text: inout AttributedString,
        classes: Set<String>,
        range: Range<AttributedString.Index>
    ) {
        for className in classes {
            if let color = defaultTextColors[className] {
                text[range].cueForegroundColor = makeColor(color)
            } else if className.hasPrefix("bg_"), let color = defaultTextColors[String(className.dropFirst(3))] {
                text[range].cueBackgroundColor = makeColor(color)
            }
        }
    }

    private static func applyStyle(
        _ style: WebvttCssStyle,
        to text: inout AttributedString,
        range: Range<AttributedString.Index>
    ) {
        guard !range.isEmpty else { return }
        if let isBold = style.isBold {
            text[range].cueBold = isBold
        }
        if let isItalic = style.isItalic {
            text[range].cueItalic = isItalic
        }
        if style.isLinethrough {
            text[range].cueStrikethrough = true
        }
        if style.isUnderline {
            text[range].cueUnderline = true
        }
        if let fontColor = style.fontColor {
            text[range].cueForegroundColor = fontColor
        }
        if let backgroundColor = style.backgroundColor {
            text[range].cueBackgroundColor = backgroundColor
        }
        if let fontFamily = style.fontFamily {
            text[range].cueFontFamily = fontFamily
        }
        switch style.fontSizeUnit {
        case .pixel:
            text[range].cueAbsoluteFontSize = style.fontSize
        case .em:
            text[range].cueRelativeFontSize = style.fontSize
        case .percent:
            text[range].cueRelativeFontSize = style.fontSize / 100
        case nil:
            break
        }
        if style.combinesUpright {
            text[range].cueHorizontalInVertical = true
        }
    }

    /// The styles that match the tag, least specific first, so that the most specific one is applied last.
    private static func applicableStyles(_ styles: [WebvttCssStyle], cueId: String?, tag: StartTag) -> [WebvttCssStyle] {
        styles
            .compactMap { style -> (score: Int, style: WebvttCssStyle)? in
                let score = style.specificityScore(id: cueId, tag: tag.name, classes: tag.classes, voice: tag.voice)
                return score > 0 ? (score, style) : nil
            }
            .enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score < $1.element.score : $0.offset < $1.offset }
            .map(\.element.style)
    }

    private static func makeColor(_ rgb: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    private static let defaultTextColors: [String: UInt32] = [
        "white": 0xFFFFFF, "lime": 0x00FF00, "cyan": 0x00FFFF, "red": 0xFF0000,
        "yellow": 0xFFFF00, "magenta": 0xFF00FF, "blue": 0x0000FF, "black": 0x000000,
    ]
}

// MARK: - Tags

private extension WebvttCueParser {
    struct StartTag {
        let name: String
        let position: Int
        let voice: String
        let classes: Set<String>

        /// A tag that spans the whole cue, for the styles of the cue itself.
        static let wholeCue = StartTag(name: "", position: 0, voice: "", classes: [])

        init(name: String, position: Int, voice: String, classes: Set<String>) {
            self.name = name
            self.position = position
            self.voice = voice
            self.classes = classes
        }

        /// Parses `name.class1.class2 annotation`; the annotation of a `<v>` tag is the voice.
        init(fullTagExpression: String, position: Int) {
            var expression = fullTagExpression.trimmingCharacters(in: .whitespaces)
            var voice = ""
            if let voiceStartIndex = expression.firstIndex(of: " ") {
                voice = expression[voiceStartIndex...].trimmingCharacters(in: .whitespaces)
                expression = String(expression[..<voiceStartIndex])
            }
            let nameAndClasses = expression.split(separator: ".", omittingEmptySubsequences: false)
            self.init(
                name: String(nameAndClasses.first ?? ""),
                position: position,
                voice: voice,
                classes: Set(nameAndClasses.dropFirst().filter { !$0.isEmpty }.map(String.init))
            )
        }
    }

    /// A closed element inside a tag that is still open, as the `<rt>` elements of a `<ruby>`.
    struct Element {
        let startTag: StartTag
        let endPosition: Int
    }
}

private extension Character {
    static let tagStart: Character = "<"
    static let tagEnd: Character = ">"
    static let entityStart: Character = "&"
}

private extension String {
    static let tagBold = "b"
    static let tagClass = "c"
    static let tagItalic = "i"
    static let tagLang = "lang"
    static let tagRuby = "ruby"
    static let tagRubyText = "rt"
    static let tagUnderline = "u"
    static let tagVoice = "v"
}

// MARK: - Cue info builder

/// Collects the settings of a cue and turns them into a ``Cue``, deriving what the cue doesn't set as WebVTT says.
struct WebvttCueInfoBuilder {
    enum TextAlignment {
        case start
        case center
        case end
        case left
        case right
    }

    /// The default size of a cue, as a fraction of the viewport.
    static let defaultSize: CGFloat = 1

    var startTime: CMTime = .zero
    var endTime: CMTime = .zero
    var text: AttributedString?
    var textAlignment: TextAlignment = .center
    /// A line number when ``snapToLines``, else a fraction of the viewport; `nil` if unset.
    var line: CGFloat?
    /// Whether the line is a number of lines rather than a fraction. Lines snap by default.
    var snapToLines = true
    var lineAnchor: Cue.Anchor?
    var position: CGFloat?
    var positionAnchor: Cue.Anchor?
    var size: CGFloat = defaultSize
    var verticalType: Cue.VerticalType?

    func build() -> WebvttCueInfo {
        WebvttCueInfo(cue: toCueBuilder().build(), startTime: startTime, endTime: endTime)
    }

    func toCueBuilder() -> Cue.Builder {
        let position = position ?? Self.derivePosition(textAlignment)
        let positionAnchor = positionAnchor ?? Self.derivePositionAnchor(textAlignment)
        return Cue.Builder()
            .setText(text ?? AttributedString())
            .setTextAlignment(Self.convertTextAlignment(textAlignment))
            .setLine(computeLine())
            .setLineAnchor(lineAnchor)
            .setPosition(position)
            .setPositionAnchor(positionAnchor)
            .setSize(min(size, Self.deriveMaxSize(positionAnchor: positionAnchor, position: position)))
            .setVerticalType(verticalType)
    }

    /// The line of the cue: a fraction out of range moves to the bottom, and an unset fraction is the bottom. An
    /// unset line number is left for the subtitle to stack the cue with the others.
    private func computeLine() -> Cue.Line? {
        if snapToLines {
            return line.map { .number(Int($0)) }
        }
        guard let line, (0 ... 1).contains(line) else { return .fraction(1) }
        return .fraction(line)
    }

    private static func derivePosition(_ textAlignment: TextAlignment) -> CGFloat {
        switch textAlignment {
        case .left: 0
        case .right: 1
        case .start,
             .center,
             .end: 0.5
        }
    }

    private static func derivePositionAnchor(_ textAlignment: TextAlignment) -> Cue.Anchor {
        switch textAlignment {
        case .left,
             .start: .start
        case .right,
             .end: .end
        case .center: .middle
        }
    }

    private static func convertTextAlignment(_ textAlignment: TextAlignment) -> Cue.Alignment {
        switch textAlignment {
        case .start,
             .left: .leading
        case .center: .center
        case .end,
             .right: .trailing
        }
    }

    /// The largest size the cue can have at its position without leaving the viewport.
    private static func deriveMaxSize(positionAnchor: Cue.Anchor, position: CGFloat) -> CGFloat {
        switch positionAnchor {
        case .start: 1 - position
        case .end: position
        case .middle: position <= 0.5 ? position * 2 : (1 - position) * 2
        }
    }
}
