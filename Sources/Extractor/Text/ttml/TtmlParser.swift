//
//  TtmlParser.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.ttml.TtmlParser
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import SEPlayerCommon

/// A ``SubtitleParser`` for TTML, with the IMSC and EBU-TT-D profiles it is carried in.
///
/// The head declares styles, regions and images; the paragraphs of the body show in their regions between their times,
/// with the styles of the elements around their text. Times are clock times, `01:02:03.4` or `01:02:03:04` with
/// frames, or offsets such as `5s`, `10f` and `300t` with the frame and tick rates of the document.
public final class TtmlParser: SubtitleParser {
    public static let cueReplacementBehavior = CueReplacementBehavior.merge

    public init() {}

    public func getCueReplacementBehavior() -> CueReplacementBehavior {
        Self.cueReplacementBehavior
    }

    public func parse(
        data: BlockBufferReader,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws {
        let element = try XmlElement(document: data)
        guard element.name == TtmlTag.tt else {
            throw ParserError.createForMalformedDataOfUnknownType(message: "A TTML document starts with \(element.name)")
        }

        var document = Document(root: element)
        let root = try makeNode(element, parent: nil, document: document)
        readChildren(of: element, into: root, document: &document)
        if !document.skippedTags.isEmpty {
            SELogger.warning(.subtitles, "Skipping unsupported TTML elements: \(document.skippedTags.sorted())")
        }

        let subtitle = TtmlSubtitle(
            root: root,
            globalStyles: document.styles,
            regions: document.regions,
            images: document.images
        )
        try subtitle.toCuesWithTiming(outputOptions: outputOptions, output: output)
    }

    /// Adds the nodes of the elements and texts in `element` to `node`. Elements it doesn't know or can't read are
    /// left out with what they contain; the head fills the declarations of the document instead.
    private func readChildren(of element: XmlElement, into node: TtmlNode, document: inout Document) {
        for child in element.children {
            switch child {
            case let .text(text):
                node.addChild(TtmlNode(text: text, timeRange: node.timeRange))
            case let .element(childElement) where childElement.name == TtmlTag.head:
                readHead(childElement, document: &document)
            case let .element(childElement) where Self.supportedTags.contains(childElement.name):
                do {
                    let childNode = try makeNode(childElement, parent: node, document: document)
                    node.addChild(childNode)
                    readChildren(of: childElement, into: childNode, document: &document)
                } catch {
                    SELogger.warning(.subtitles, "Skipping the TTML element \(childElement.name): \(error)")
                }
            case let .element(childElement):
                document.skippedTags.insert(childElement.name)
            }
        }
    }

    /// Reads the styles, regions and images the head declares, in order: styles may refer to those before them.
    private func readHead(_ element: XmlElement, document: inout Document) {
        for child in element.elements {
            switch child.name {
            case TtmlTag.style:
                var style = parseStyleAttributes(child, into: TtmlStyle()) ?? TtmlStyle()
                for id in Self.parseStyleIds(child.attributes[.style]) {
                    style = style.chained(to: document.styles[id])
                }
                if let id = style.id {
                    document.styles[id] = style
                }
            case TtmlTag.region:
                if let region = parseRegion(child, document: document) {
                    document.regions[region.id] = region
                }
            case TtmlTag.metadata:
                let images = child.descendantsAndSelf.filter { $0.name == TtmlTag.image }
                for image in images {
                    // Decoded once here, not each time a cue shows it.
                    guard let id = image.attributes[.id], let decoded = Self.decodeImage(image.text) else {
                        continue
                    }
                    document.images[id] = decoded
                }
                continue
            default:
                break
            }
            readHead(child, document: &document)
        }
    }

    private func makeNode(_ element: XmlElement, parent: TtmlNode?, document: Document) throws -> TtmlNode {
        let attributes = element.attributes
        let begin = try attributes[.begin].map { try parseTimeExpression($0, rates: document.rates) }
        let end = try attributes[.end].map { try parseTimeExpression($0, rates: document.rates) }
        let duration = try attributes[.duration].map { try parseTimeExpression($0, rates: document.rates) }

        // A region that isn't declared, or that couldn't be read, is the anonymous one.
        let regionId = attributes[.region].flatMap { document.regions[$0]?.id } ?? TtmlRegion.anonymous.id
        // Only images of the document itself.
        let imageId = attributes[.backgroundImage].flatMap { value in
            value.hasPrefix("#") ? String(value.dropFirst()) : nil
        }

        // Times are relative to the parent. Without a begin, an element starts with its parent; without an end or a
        // duration, it ends with it, and the root never does.
        let parentStart = parent?.timeRange.start ?? .zero
        let startTime = (begin ?? .zero) + parentStart
        let endTime = if let end {
            end + parentStart
        } else if let duration {
            startTime + duration
        } else {
            parent?.timeRange.end ?? .positiveInfinity
        }

        return TtmlNode(
            tag: element.name,
            timeRange: CMTimeRange(start: startTime, end: endTime),
            style: parseStyleAttributes(element, into: nil),
            styleIds: Self.parseStyleIds(attributes[.style]),
            regionId: regionId,
            imageId: imageId,
            parent: parent
        )
    }

    /// The region an element declares, with a percentage or pixel origin and extent, or `nil` if it can't be placed.
    /// Pixels are converted with the extent of the document.
    private func parseRegion(_ element: XmlElement, document: Document) -> TtmlRegion? {
        guard let id = element.attributes[.id] else { return nil }
        let referredStyle = element.attributes[.style].flatMap { document.styles[$0] }

        var position: CGFloat = 0
        var line: CGFloat = 0
        if let origin = element.attributes[.origin] ?? referredStyle?.origin {
            guard let coordinates = parseCoordinates(origin, extent: document.extent) else {
                SELogger.debug(.subtitles, "Skipping the TTML region \(id) with the origin \(origin)")
                return nil
            }
            (position, line) = (coordinates.x, coordinates.y)
        }

        // Without an extent, the region is the size of the viewport.
        var width: CGFloat = 1
        var height: CGFloat = 1
        if let extent = element.attributes[.extent] ?? referredStyle?.extent {
            guard let size = parseCoordinates(extent, extent: document.extent) else {
                SELogger.debug(.subtitles, "Skipping the TTML region \(id) with the extent \(extent)")
                return nil
            }
            (width, height) = (size.x, size.y)
        }

        var lineAnchor = Cue.Anchor.start
        switch (element.attributes[.displayAlign] ?? referredStyle?.displayAlign)?.lowercased() {
        case "center":
            lineAnchor = .middle
            line += height / 2
        case "after":
            lineAnchor = .end
            line += height
        default:
            break
        }

        let verticalType: Cue.VerticalType? = switch element.attributes[.writingMode]?.lowercased() {
        case "tb",
             "tblr": .leftToRight
        case "tbrl": .rightToLeft
        default: nil
        }

        return TtmlRegion(
            id: id,
            position: position,
            line: line,
            lineAnchor: lineAnchor,
            width: width,
            height: height,
            textSize: 1 / CGFloat(document.cellRows),
            verticalType: verticalType
        )
    }

    /// The style attributes of an element over `style`, or `style` if it has none.
    private func parseStyleAttributes(_ element: XmlElement, into style: TtmlStyle?) -> TtmlStyle? {
        // The id of a `style` element is that of the style.
        let styleAttributes = element.attributes.filter { name, _ in
            Self.styleAttributes.contains(name) || (name == .id && element.name == TtmlTag.style)
        }
        guard style != nil || !styleAttributes.isEmpty else { return nil }

        var style = style ?? TtmlStyle()
        for (name, value) in styleAttributes {
            switch name {
            case .id:
                style.id = value
            case .backgroundColor:
                style.backgroundColor = parseColor(value, attribute: name)
            case .color:
                style.fontColor = parseColor(value, attribute: name)
            case .fontFamily:
                style.fontFamily = value
            case .fontSize:
                style.fontSize = parseFontSize(value)
            case .fontWeight:
                style.isBold = value.lowercased() == "bold"
            case .fontStyle:
                style.isItalic = value.lowercased() == "italic"
            case .textAlign:
                style.textAlign = parseAlignment(value)
            case .multiRowAlign:
                style.multiRowAlign = parseAlignment(value)
            case .textCombine:
                switch value.lowercased() {
                case "none": style.textCombine = false
                case "all": style.textCombine = true
                default: break
                }
            case .ruby:
                if let rubyType = parseRubyType(value) {
                    style.rubyType = rubyType
                }
            case .rubyPosition:
                switch value.lowercased() {
                case "before": style.rubyPosition = .before
                case "after": style.rubyPosition = .after
                default: break
                }
            case .textDecoration:
                switch value.lowercased() {
                case "linethrough": style.isLinethrough = true
                case "nolinethrough": style.isLinethrough = false
                case "underline": style.isUnderline = true
                case "nounderline": style.isUnderline = false
                default: break
                }
            case .textEmphasis:
                style.textEmphasis = TtmlTextEmphasis(value)
            case .shear:
                style.shearPercentage = parseShear(value)
            case .origin:
                style.origin = value
            case .extent:
                style.extent = value
            case .displayAlign:
                style.displayAlign = value
            default:
                break
            }
        }
        return style
    }

    private func parseColor(_ value: String, attribute: String) -> CGColor? {
        let color = CssColorParser.parseTtmlColor(value)
        if color == nil {
            SELogger.debug(.subtitles, "Skipping the TTML \(attribute) \(value)")
        }
        return color
    }

    private func parseAlignment(_ value: String) -> Cue.Alignment? {
        switch value.lowercased() {
        case "left",
             "start": .leading
        case "right",
             "end": .trailing
        case "center": .center
        default: nil
        }
    }

    private func parseRubyType(_ value: String) -> TtmlStyle.RubyType? {
        switch value.lowercased() {
        case "container": .container
        case "base",
             "basecontainer": .base
        case "text",
             "textcontainer": .text
        case "delimiter": .delimiter
        default: nil
        }
    }

    /// A size in pixels, ems or percent. Of two sizes, horizontal and vertical, the vertical one.
    private func parseFontSize(_ value: String) -> TtmlStyle.FontSize? {
        let sizes = value.split(whereSeparator: \.isWhitespace)
        guard let size = sizes.last, sizes.count <= 2 else {
            SELogger.debug(.subtitles, "Skipping the TTML font size \(value)")
            return nil
        }
        if size.hasSuffix("px"), let pixels = parseNumber(size.dropLast(2), isSigned: false) {
            return .pixels(pixels)
        } else if size.hasSuffix("em"), let em = parseNumber(size.dropLast(2), isSigned: false) {
            return .em(em)
        } else if size.hasSuffix("%"), let percentage = parseNumber(size.dropLast(), isSigned: false) {
            return .percent(percentage)
        }
        SELogger.debug(.subtitles, "Skipping the TTML font size \(value)")
        return nil
    }

    /// A shear from -100% to 100%: larger values are clamped to these.
    private func parseShear(_ value: String) -> CGFloat? {
        guard value.hasSuffix("%"), let percentage = parseNumber(value.dropLast(), isSigned: true) else {
            SELogger.debug(.subtitles, "Skipping the TTML shear \(value)")
            return nil
        }
        return min(max(percentage, -100), 100)
    }

    /// Two percentages, `"10% 80%"`, as fractions, or two pixel values as fractions of `extent`.
    private func parseCoordinates(_ value: String, extent: CGSize?) -> CGPoint? {
        let parts = value.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts.allSatisfy({ $0.hasSuffix("%") }) {
            guard let x = parseNumber(parts[0].dropLast(), isSigned: true),
                  let y = parseNumber(parts[1].dropLast(), isSigned: true) else {
                return nil
            }
            return CGPoint(x: x / 100, y: y / 100)
        }
        if parts.allSatisfy({ $0.hasSuffix("px") }), let extent {
            guard let x = parseNumber(parts[0].dropLast(2), isSigned: true),
                  let y = parseNumber(parts[1].dropLast(2), isSigned: true) else {
                return nil
            }
            return CGPoint(x: x / extent.width, y: y / extent.height)
        }
        return nil
    }

    /// A time expression: a clock time, `hh:mm:ss[.fraction]` or `hh:mm:ss:ff[.subframes]`, or an offset, a number
    /// with a unit of `h`, `m`, `s`, `ms`, `f` (frames) or `t` (ticks).
    private func parseTimeExpression(_ value: String, rates: FrameAndTickRate) throws -> CMTime {
        if let seconds = parseClockTime(value, rates: rates) ?? parseOffsetTime(value, rates: rates) {
            return CMTime(value: Int64(seconds * Double(Self.timescale)), timescale: Self.timescale)
        }
        throw ParserError.createForMalformedDataOfUnknownType(message: "Malformed TTML time expression: \(value)")
    }

    private func parseClockTime(_ value: String, rates: FrameAndTickRate) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 4,
              let hours = parseDigits(parts[0], minimumCount: 2),
              let minutes = parseDigits(parts[1], count: 2) else {
            return nil
        }
        var seconds = Double(hours * 3600 + minutes * 60)

        if parts.count == 3 {
            // Seconds, with a fraction.
            let secondParts = parts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard let wholeSeconds = parseDigits(secondParts[0], count: 2) else {
                return nil
            }

            seconds += Double(wholeSeconds)
            if secondParts.count == 2 {
                guard isDigits(secondParts[1]), let fraction = Double("0.\(secondParts[1])") else {
                    return nil
                }

                seconds += fraction
            }

            return seconds
        }

        // Seconds, then frames, with subframes.
        guard let wholeSeconds = parseDigits(parts[2], count: 2) else {
            return nil
        }

        seconds += Double(wholeSeconds)
        let frameParts = parts[3].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let frames = parseDigits(frameParts[0], count: 2) else {
            return nil
        }

        seconds += Double(frames) / rates.effectiveFrameRate
        if frameParts.count == 2 {
            guard let subframes = parseDigits(frameParts[1], minimumCount: 1) else {
                return nil
            }

            seconds += Double(subframes) / Double(rates.subFrameRate) / rates.effectiveFrameRate
        }

        return seconds
    }

    private func parseOffsetTime(_ value: String, rates: FrameAndTickRate) -> Double? {
        guard let unitStart = value.firstIndex(where: \.isLetter) else {
            return nil
        }

        let unit = value[unitStart...]
        guard let number = parseNumber(value[..<unitStart], isSigned: false).map(Double.init) else {
            return nil
        }

        return switch unit {
        case "h": number * 3600
        case "m": number * 60
        case "s": number
        case "ms": number / 1000
        case "f": number / rates.effectiveFrameRate
        case "t": number / Double(rates.tickRate)
        default: nil
        }
    }

    /// A decimal number, `12` or `12.5`, with a sign if `isSigned`.
    private func parseNumber(_ value: Substring, isSigned: Bool) -> CGFloat? {
        var digits = value
        if isSigned, digits.first == "-" || digits.first == "+" {
            digits = digits.dropFirst()
        }
        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard isDigits(parts[0]) else { return nil }
        if parts.count == 2, !parts[1].isEmpty, !isDigits(parts[1]) {
            return nil
        }
        return Double(value).map { CGFloat($0) }
    }

    /// The value of ASCII digits, when there are `count` of them or at least `minimumCount`.
    private func parseDigits(_ value: Substring, count: Int? = nil, minimumCount: Int = 1) -> Int? {
        guard value.count >= minimumCount, count.map({ value.count == $0 }) ?? true, isDigits(value) else {
            return nil
        }
        return Int(value)
    }

    /// Whether the value is one or more ASCII digits.
    private func isDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// An image from the base64 data of an `smpte:image` element.
    private static func decodeImage(_ encodedImage: String) -> CGImage? {
        guard let data = Data(base64Encoded: encodedImage, options: .ignoreUnknownCharacters) else {
            return nil
        }
        // Reads the image file, PNG in TTML, from memory; `nil` if it isn't an image.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        // Decodes the first image of the file.
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func parseStyleIds(_ value: String?) -> [String] {
        value?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
    }
}

private extension TtmlParser {
    /// The declarations of a document, and the parameters of its root.
    struct Document {
        let rates: FrameAndTickRate
        /// The rows of cells the viewport is divided into, for the size of text.
        let cellRows: Int
        /// The size of the viewport in pixels, for regions placed in pixels.
        let extent: CGSize?
        var styles: [String: TtmlStyle] = [:]
        var regions: [String: TtmlRegion] = [TtmlRegion.anonymous.id: .anonymous]
        var images: [String: CGImage] = [:]
        /// The names of the elements left out as unsupported, to report once per document.
        var skippedTags: Set<String> = []

        init(root: XmlElement) {
            rates = FrameAndTickRate(root: root)
            cellRows = Self.parseCellRows(root.attributes[.cellResolution])
            extent = Self.parseExtent(root.attributes[.extent])
        }

        /// The rows of `columns rows`.
        private static func parseCellRows(_ value: String?) -> Int {
            guard let value else { return TtmlParser.defaultCellRows }
            let parts = value.split(separator: " ", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else {
                SELogger.debug(.subtitles, "Skipping the TTML cell resolution \(value)")
                return TtmlParser.defaultCellRows
            }
            return parts[1]
        }

        /// The size of `widthpx heightpx`.
        private static func parseExtent(_ value: String?) -> CGSize? {
            guard let value else { return nil }
            let parts = value.split(separator: " ", omittingEmptySubsequences: false)
            let sizes = parts.compactMap { part in part.hasSuffix("px") ? Int(part.dropLast(2)) : nil }
            guard sizes.count == 2, sizes.allSatisfy({ $0 > 0 }) else {
                SELogger.debug(.subtitles, "Skipping the TTML extent \(value), which isn't in pixels")
                return nil
            }
            return CGSize(width: sizes[0], height: sizes[1])
        }
    }

    /// The rates frame and tick times count in.
    struct FrameAndTickRate {
        let effectiveFrameRate: Double
        let subFrameRate: Int
        let tickRate: Int

        init(root: XmlElement) {
            let frameRate = root.attributes[.frameRate].flatMap { Int($0) } ?? TtmlParser.defaultFrameRate
            var multiplier = 1.0
            if let value = root.attributes[.frameRateMultiplier] {
                let parts = value.split(separator: " ").compactMap { Int($0) }
                if parts.count == 2, parts[1] != 0 {
                    multiplier = Double(parts[0]) / Double(parts[1])
                } else {
                    SELogger.debug(.subtitles, "Skipping the TTML frame rate multiplier \(value)")
                }
            }
            effectiveFrameRate = Double(frameRate) * multiplier
            subFrameRate = root.attributes[.subFrameRate].flatMap { Int($0) } ?? 1
            tickRate = root.attributes[.tickRate].flatMap { Int($0) } ?? 1
        }
    }

    /// The timescale of the times of cues.
    static let timescale: CMTimeScale = 1_000_000
    static let defaultFrameRate = 30
    static let defaultCellRows = 15

    /// The attributes of styles, which elements may set themselves.
    static let styleAttributes: Set<String> = [
        .backgroundColor, .color, .fontFamily, .fontSize, .fontWeight, .fontStyle, .textAlign, .multiRowAlign,
        .textCombine, .ruby, .rubyPosition, .textDecoration, .textEmphasis, .shear, .origin, .extent, .displayAlign,
    ]

    static let supportedTags: Set<String> = [
        TtmlTag.tt, TtmlTag.head, TtmlTag.body, TtmlTag.division, TtmlTag.paragraph, TtmlTag.span, TtmlTag.lineBreak,
        TtmlTag.style, TtmlTag.styling, TtmlTag.layout, TtmlTag.region, TtmlTag.metadata, TtmlTag.image, TtmlTag.data,
        TtmlTag.information,
    ]
}

/// The local names of the attributes the parser reads.
private extension String {
    static let id = "id"
    static let style = "style"
    static let region = "region"
    static let begin = "begin"
    static let end = "end"
    static let duration = "dur"
    static let backgroundImage = "backgroundImage"
    static let frameRate = "frameRate"
    static let frameRateMultiplier = "frameRateMultiplier"
    static let subFrameRate = "subFrameRate"
    static let tickRate = "tickRate"
    static let cellResolution = "cellResolution"
    static let origin = "origin"
    static let extent = "extent"
    static let displayAlign = "displayAlign"
    static let writingMode = "writingMode"
    static let backgroundColor = "backgroundColor"
    static let color = "color"
    static let fontFamily = "fontFamily"
    static let fontSize = "fontSize"
    static let fontWeight = "fontWeight"
    static let fontStyle = "fontStyle"
    static let textAlign = "textAlign"
    static let multiRowAlign = "multiRowAlign"
    static let textCombine = "textCombine"
    static let ruby = "ruby"
    static let rubyPosition = "rubyPosition"
    static let textDecoration = "textDecoration"
    static let textEmphasis = "textEmphasis"
    static let shear = "shear"
}
