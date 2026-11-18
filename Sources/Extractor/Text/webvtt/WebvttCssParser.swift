//
//  WebvttCssParser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.10.2026.
//

import CoreGraphics
import Foundation

/// Parses the `::cue` rules of a WebVTT STYLE block.
final class WebvttCssParser {
    /// Reads a STYLE block up to the empty line that ends it, and parses its rules. The STYLE line itself was read.
    func parseBlock(_ reader: inout WebvttLineReader) -> [WebvttCssStyle] {
        var lines: [String] = []
        while let line = reader.readLine(), !line.isEmpty {
            lines.append(line)
        }
        var input = Scanner(text: lines.joined(separator: "\n"))
        return parseRules(&input)
    }

    private func parseRules(_ input: inout Scanner) -> [WebvttCssStyle] {
        var styles: [WebvttCssStyle] = []
        while let selector = parseSelector(&input) {
            guard parseNextToken(&input) == .ruleStart else { return styles }
            let style = WebvttCssStyle()
            applySelector(selector, to: style)

            var token: String?
            var blockEndFound = false
            while !blockEndFound {
                let position = input.position
                token = parseNextToken(&input)
                blockEndFound = token == nil || token == .ruleEnd
                if !blockEndFound {
                    input.position = position
                    parseStyleDeclaration(&input, style: style)
                }
            }
            // A rule that isn't closed is dropped.
            if token == .ruleEnd {
                styles.append(style)
            }
        }
        return styles
    }

    /// Reads `::cue` and its target in parentheses, if any. Returns `""` for a rule without a target, or `nil` if
    /// there is no other rule or it is not a `::cue` rule.
    private func parseSelector(_ input: inout Scanner) -> String? {
        skipWhitespaceAndComments(&input)
        guard input.bytesLeft >= 5, input.read(count: 5) == "::cue" else {
            return nil
        }
        let position = input.position
        guard let token = parseNextToken(&input) else { return nil }
        if token == .ruleStart {
            input.position = position
            return ""
        }
        var target: String?
        if token == "(" {
            target = readCueTarget(&input)
        }
        guard parseNextToken(&input) == ")" else { return nil }
        return target
    }

    /// Reads the selector inside `::cue(...)`, up to the closing parenthesis.
    private func readCueTarget(_ input: inout Scanner) -> String {
        var target = ""
        while let character = input.peek(), character != ")" {
            target.unicodeScalars.append(character)
            input.position += 1
        }
        return target.trimmingCharacters(in: .whitespaces)
    }

    private func parseStyleDeclaration(_ input: inout Scanner, style: WebvttCssStyle) {
        skipWhitespaceAndComments(&input)
        let property = parseIdentifier(&input)
        guard !property.isEmpty, parseNextToken(&input) == ":" else { return }
        skipWhitespaceAndComments(&input)
        guard let value = parsePropertyValue(&input), !value.isEmpty else {
            return
        }

        let position = input.position
        let token = parseNextToken(&input)
        if token == ";" {
            // Fine.
        } else if token == .ruleEnd {
            input.position = position
        } else {
            // The declaration is malformed.
            return
        }

        switch property {
        case .properyColor:
            style.fontColor = CssColorParser.parseCssColor(value)
        case .properyBgColor:
            style.backgroundColor = CssColorParser.parseCssColor(value)
        case .properyRubyPosition:
            if value == .valueOver {
                style.rubyPosition = .before
            } else if value == .valueUnder {
                style.rubyPosition = .after
            }
        case .propertyTextCombineUpright:
            style.combinesUpright = value == .valueAll || value.hasPrefix(.valueDigits)
        case .propertyTextDecoration:
            if value == .valueUnderline {
                style.isUnderline = true
            }
        case .properyFamily:
            style.fontFamily = value
        case .properyWeight:
            if value == .valueBold {
                style.isBold = true
            }
        case .propertyFontStyle:
            if value == .valueItalic {
                style.isItalic = true
            }
        case .properyFontSize:
            parseFontSize(value, style: style)
        default:
            break
        }
    }

    /// Reads a font size in `px`, `em` or `%`.
    private func parseFontSize(_ value: String, style: WebvttCssStyle) {
        let unit: WebvttCssStyle.FontSizeUnit
        let number: Substring
        if value.hasSuffix("px") {
            unit = .pixel
            number = value.dropLast(2)
        } else if value.hasSuffix("em") {
            unit = .em
            number = value.dropLast(2)
        } else if value.hasSuffix("%") {
            unit = .percent
            number = value.dropLast(1)
        } else {
            return
        }

        // Only plain decimal numbers: `Double` would also take exponents and signs.
        let isDecimal = number.allSatisfy { $0.isNumber || $0 == "." }
        guard isDecimal, let size = Double(number) else {
            return
        }

        style.fontSizeUnit = unit
        style.fontSize = CGFloat(size)
    }

    /// Applies a selector of the form `tag#id.class1.class2[voice="name"]`; any part may be missing.
    private func applySelector(_ selector: String, to style: WebvttCssStyle) {
        // A selector without target applies to all cues.
        guard !selector.isEmpty else { return }

        var selector = Substring(selector)
        if let voiceStartIndex = selector.firstIndex(of: "[") {
            let voicePart = selector[voiceStartIndex...]
            if voicePart.hasPrefix("[voice=\""), voicePart.hasSuffix("\"]") {
                style.setTargetVoice(String(voicePart.dropFirst(8).dropLast(2)))
            }
            selector = selector[..<voiceStartIndex]
        }

        let classDivision = selector.split(separator: ".", omittingEmptySubsequences: false)
        let tagAndId = classDivision.first ?? ""
        if let idPrefixIndex = tagAndId.firstIndex(of: "#") {
            style.setTargetTagName(String(tagAndId[..<idPrefixIndex]))
            style.setTargetId(String(tagAndId[tagAndId.index(after: idPrefixIndex)...]))
        } else {
            style.setTargetTagName(String(tagAndId))
        }
        if classDivision.count > 1 {
            style.setTargetClasses(classDivision.dropFirst().map(String.init))
        }
    }

    // MARK: - Tokens

    /// Reads the value of a declaration, up to `;` or `}`.
    private func parsePropertyValue(_ input: inout Scanner) -> String? {
        var expression = ""
        while true {
            let position = input.position
            guard let token = parseNextToken(&input) else { return nil }
            if token == .ruleEnd || token == ";" {
                input.position = position
                return expression
            }
            expression += token
        }
    }

    /// Reads an identifier, or else a single character; `nil` at the end of the input.
    private func parseNextToken(_ input: inout Scanner) -> String? {
        skipWhitespaceAndComments(&input)
        guard input.bytesLeft > 0 else { return nil }
        let identifier = parseIdentifier(&input)
        if !identifier.isEmpty { return identifier }
        guard let character = input.peek() else { return nil }
        input.position += 1
        return String(character)
    }

    private func parseIdentifier(_ input: inout Scanner) -> String {
        var identifier = ""
        while let character = input.peek(), Self.isIdentifierCharacter(character) {
            identifier.unicodeScalars.append(character)
            input.position += 1
        }
        return identifier
    }

    private static func isIdentifierCharacter(_ character: Unicode.Scalar) -> Bool {
        switch character {
        case "A"..."Z", "a"..."z", "0"..."9", "#", "-", ".", "_": true
        default: false
        }
    }

    private func skipWhitespaceAndComments(_ input: inout Scanner) {
        var skipping = true
        while input.bytesLeft > 0, skipping {
            skipping = maybeSkipWhitespace(&input) || maybeSkipComment(&input)
        }
    }

    private func maybeSkipWhitespace(_ input: inout Scanner) -> Bool {
        switch input.peek() {
        case "\t", "\r", "\n", "\u{0C}", " ":
            input.position += 1
            return true
        default:
            return false
        }
    }

    /// Skips a `/* ... */` comment, to the end of the input if it isn't closed.
    private func maybeSkipComment(_ input: inout Scanner) -> Bool {
        guard input.peek() == "/", input.peek(offset: 1) == "*" else {
            return false
        }
        input.position += 2
        while input.bytesLeft > 0 {
            if input.peek() == "*", input.peek(offset: 1) == "/" {
                input.position += 2
                return true
            }
            input.position += 1
        }
        return true
    }
}

private extension WebvttCssParser {
    struct Scanner {
        let characters: [Unicode.Scalar]
        var position = 0

        init(text: String) {
            characters = Array(text.unicodeScalars)
        }

        var bytesLeft: Int { characters.count - position }

        func peek(offset: Int = 0) -> Unicode.Scalar? {
            let index = position + offset
            return index < characters.count ? characters[index] : nil
        }

        mutating func read(count: Int) -> String {
            let end = min(characters.count, position + count)
            var string = ""
            string.unicodeScalars.append(contentsOf: characters[position..<end])
            position = end
            return string
        }
    }
}

private extension String {
    static let ruleStart = "{";
    static let ruleEnd = "}";
    static let properyColor = "color";
    static let properyBgColor = "background-color";
    static let properyFamily = "font-family";
    static let properyWeight = "font-weight";
    static let properyFontSize = "font-size";
    static let properyRubyPosition = "ruby-position";
    static let valueOver = "over";
    static let valueUnder = "under";
    static let propertyTextCombineUpright = "text-combine-upright";
    static let valueAll = "all";
    static let valueDigits = "digits";
    static let propertyTextDecoration = "text-decoration";
    static let valueBold = "bold";
    static let valueUnderline = "underline";
    static let propertyFontStyle = "font-style";
    static let valueItalic = "italic";
}
