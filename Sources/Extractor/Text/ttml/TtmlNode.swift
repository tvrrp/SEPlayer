//
//  TtmlNode.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.ttml.TtmlNode
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics
import CoreMedia
import Foundation
import SEPlayerCommon

/// An element of a TTML document, or a text in one, with its times resolved against its parents.
///
/// The cues at a time are one per region: the text of the paragraphs that show then, with the styles of the elements
/// around each part.
final class TtmlNode {
    /// The local name of the element, or `nil` for a text.
    let tag: String?
    /// The text, with the white space TTML collapses collapsed, or `nil` for an element.
    let text: String?
    /// When the node shows, resolved against its parents. It may go on forever.
    let timeRange: CMTimeRange
    /// The style attributes of the element itself.
    let style: TtmlStyle?
    /// The styles the element refers to, in order.
    let styleIds: [String]
    /// The region of the element, or empty if it is in the region of its parent.
    let regionId: String
    /// The `smpte:image` the element shows, if it is a `div` with a background image.
    let imageId: String?

    private(set) weak var parent: TtmlNode?
    private(set) var children: [TtmlNode] = []

    /// All the times a cue starts or ends, in increasing order.
    var eventTimes: [CMTime] {
        var times = Set<CMTime>()
        collectEventTimes(into: &times, descendsParagraph: false)
        return times.sorted()
    }

    init(
        tag: String,
        timeRange: CMTimeRange,
        style: TtmlStyle?,
        styleIds: [String],
        regionId: String,
        imageId: String?,
        parent: TtmlNode?
    ) {
        self.tag = tag
        text = nil
        self.timeRange = timeRange
        self.style = style
        self.styleIds = styleIds
        self.regionId = regionId
        self.imageId = imageId
        self.parent = parent
    }

    /// A text of an element, which shows when the element does.
    init(text: String, timeRange: CMTimeRange) {
        tag = nil
        self.text = Self.applyingSpacePolicy(text)
        self.timeRange = timeRange
        style = nil
        styleIds = []
        regionId = TtmlRegion.anonymous.id
        imageId = nil
    }

    func addChild(_ child: TtmlNode) {
        children.append(child)
    }

    func isActive(at time: CMTime) -> Bool {
        timeRange.containsTime(time)
    }

    /// The cues of the document at `time`, if the node is its root.
    func cues(
        at time: CMTime,
        globalStyles: [String: TtmlStyle],
        regions: [String: TtmlRegion],
        images: [String: CGImage]
    ) -> [Cue] {
        var imageOutputs: [(regionId: String, imageId: String)] = []
        collectImages(at: time, inheritedRegion: regionId, into: &imageOutputs)

        var textOutputs: [String: RegionOutput] = [:]
        var styledNodes: [StyledNode] = []
        collectText(
            at: time,
            descendsParagraph: false,
            inheritedRegion: regionId,
            outputs: &textOutputs,
            styledNodes: &styledNodes
        )
        // Parents first, so that the styles of the elements in them apply over theirs.
        for styledNode in styledNodes {
            let verticalType = regions[styledNode.regionId]?.verticalType
            for (outputRegion, end) in styledNode.ends {
                let start = styledNode.starts[outputRegion] ?? 0
                guard start != end, var output = textOutputs[outputRegion] else {
                    continue
                }
                styledNode.node.applyStyle(
                    to: &output,
                    range: start ..< end,
                    globalStyles: globalStyles,
                    verticalType: verticalType
                )
                textOutputs[outputRegion] = output
            }
        }

        var cues: [Cue] = []
        for (regionId, imageId) in imageOutputs {
            guard let region = regions[regionId], let image = images[imageId] else {
                continue
            }

            let cue = Cue.Builder()
                .setImage(image)
                .setPosition(region.position)
                .setPositionAnchor(.start)
                .setLine(region.line.map(Cue.Line.fraction))
                .setLineAnchor(region.lineAnchor)
                .setSize(region.width)
                .setImageHeight(region.height)
                .setVerticalType(region.verticalType)
                .build()
            cues.append(cue)
        }

        for regionId in textOutputs.keys.sorted() {
            guard let output = textOutputs[regionId], let region = regions[regionId] else {
                continue
            }
            // A paragraph that shows may have no text that does.
            let text = Self.cleanedUp(output.text)
            guard !text.characters.isEmpty else { continue }

            let cue = Cue.Builder()
                .setText(text)
                .setTextAlignment(output.textAlignment)
                .setMultiRowAlignment(output.multiRowAlignment)
                .setShearDegrees(output.shearDegrees)
                .setLine(region.line.map(Cue.Line.fraction))
                .setLineAnchor(region.lineAnchor)
                .setPosition(region.position)
                .setSize(region.width)
                .setTextSize(region.textSize.map(Cue.TextSize.fractionalIgnoringPadding))
                .setVerticalType(region.verticalType)
                .build()
            cues.append(cue)
        }
        return cues
    }

    private func collectEventTimes(into times: inout Set<CMTime>, descendsParagraph: Bool) {
        let isParagraph = tag == TtmlTag.paragraph
        if descendsParagraph || isParagraph || (tag == TtmlTag.division && imageId != nil) {
            times.insert(timeRange.start)
            // Not the end of a node that goes on forever.
            if timeRange.end.isNumeric { times.insert(timeRange.end) }
        }
        for child in children {
            child.collectEventTimes(into: &times, descendsParagraph: descendsParagraph || isParagraph)
        }
    }

    private func collectImages(
        at time: CMTime,
        inheritedRegion: String,
        into outputs: inout [(regionId: String, imageId: String)]
    ) {
        let resolvedRegion = regionId.isEmpty ? inheritedRegion : regionId
        if tag == TtmlTag.division, let imageId, isActive(at: time) {
            outputs.append((resolvedRegion, imageId))
            return
        }
        for child in children {
            child.collectImages(at: time, inheritedRegion: resolvedRegion, into: &outputs)
        }
    }

    /// Appends the text that shows at `time` to the output of its region, and notes where in the outputs each
    /// element's text is, for its style.
    private func collectText(
        at time: CMTime,
        descendsParagraph: Bool,
        inheritedRegion: String,
        outputs: inout [String: RegionOutput],
        styledNodes: inout [StyledNode]
    ) {
        guard tag != TtmlTag.metadata else { return }
        let resolvedRegion = regionId.isEmpty ? inheritedRegion : regionId

        if let text, descendsParagraph {
            outputs[resolvedRegion, default: RegionOutput()].text.append(AttributedString(text))
        } else if tag == TtmlTag.lineBreak, descendsParagraph {
            outputs[resolvedRegion, default: RegionOutput()].text.append(AttributedString("\n"))
        } else if tag != nil, isActive(at: time) {
            let index = styledNodes.count
            styledNodes.append(StyledNode(node: self, regionId: resolvedRegion, starts: outputs.mapValues(\.length)))

            let isParagraph = tag == TtmlTag.paragraph
            for child in children {
                child.collectText(
                    at: time,
                    descendsParagraph: descendsParagraph || isParagraph,
                    inheritedRegion: resolvedRegion,
                    outputs: &outputs,
                    styledNodes: &styledNodes
                )
            }
            if isParagraph {
                Self.endParagraph(&outputs[resolvedRegion, default: RegionOutput()].text)
            }
            styledNodes[index].ends = outputs.mapValues(\.length)
        }
    }

    private func applyStyle(
        to output: inout RegionOutput,
        range: Range<Int>,
        globalStyles: [String: TtmlStyle],
        verticalType: Cue.VerticalType?
    ) {
        guard let style = TtmlStyle.resolve(style, styleIds: styleIds, globalStyles: globalStyles) else {
            return
        }

        let textRange = Self.range(of: output.text, scalars: range)
        let attributes = attributes(of: style, globalStyles: globalStyles, verticalType: verticalType)
        output.text[textRange].mergeAttributes(attributes)
        // A relative size scales the size the elements around this one set, which can differ along the range.
        switch style.fontSize {
        case let .em(scale):
            Self.scaleRelativeFontSize(of: &output.text, range: textRange, by: scale)
        case let .percent(percentage):
            Self.scaleRelativeFontSize(of: &output.text, range: textRange, by: percentage / 100)
        case .pixels,
             nil:
            break
        }

        // Shear and alignment are of the block a paragraph makes.
        guard tag == TtmlTag.paragraph else { return }
        if let shear = style.shearPercentage {
            // A positive shear slants the tops to the right, against the angle in graphics coordinates.
            output.shearDegrees = shear * -90 / 100
        }
        if let textAlign = style.textAlign {
            output.textAlignment = textAlign
        }
        if let multiRowAlign = style.multiRowAlign {
            output.multiRowAlignment = multiRowAlign
        }
    }

    /// The attributes the style sets on the text of the element, all but a relative font size.
    private func attributes(
        of style: TtmlStyle,
        globalStyles: [String: TtmlStyle],
        verticalType: Cue.VerticalType?
    ) -> AttributeContainer {
        var attributes = AttributeContainer()
        attributes.cueBold = style.isBold
        attributes.cueItalic = style.isItalic
        attributes.cueStrikethrough = style.isLinethrough
        attributes.cueUnderline = style.isUnderline
        attributes.cueForegroundColor = style.fontColor
        attributes.cueBackgroundColor = style.backgroundColor
        attributes.cueFontFamily = style.fontFamily
        attributes.cueTextEmphasis = style.textEmphasis?.resolved(isVertical: verticalType != nil)
        switch style.rubyType {
        case .base:
            attributes.cueRuby = rubyAnnotation(globalStyles: globalStyles)
        case .text,
             .delimiter:
            // Removed when the text is complete: the ranges of the other elements are offsets into it as it is.
            attributes[TtmlDeletedTextAttribute.self] = true
        case .container,
             nil:
            break
        }
        if style.textCombine == true {
            attributes.cueHorizontalInVertical = true
        }
        if case let .pixels(size) = style.fontSize {
            attributes.cueAbsoluteFontSize = size
        }
        return attributes
    }

    /// The ruby text of a ruby base: the text of the ruby text element of the container around it.
    private func rubyAnnotation(globalStyles: [String: TtmlStyle]) -> Cue.Ruby? {
        guard let container = rubyContainer(globalStyles: globalStyles),
              let textNode = container.rubyTextNode(globalStyles: globalStyles) else {
            return nil
        }
        guard textNode.children.count == 1, let rubyText = textNode.children[0].text else {
            SELogger.debug(.subtitles, "Skipping a TTML ruby text without exactly one text in it")
            return nil
        }
        let textStyle = TtmlStyle.resolve(textNode.style, styleIds: textNode.styleIds, globalStyles: globalStyles)
        let containerStyle = TtmlStyle.resolve(container.style, styleIds: container.styleIds, globalStyles: globalStyles)
        let position = textStyle?.rubyPosition ?? containerStyle?.rubyPosition
        return Cue.Ruby(text: rubyText, position: position)
    }

    private func rubyContainer(globalStyles: [String: TtmlStyle]) -> TtmlNode? {
        var node = parent
        while let current = node {
            let style = TtmlStyle.resolve(current.style, styleIds: current.styleIds, globalStyles: globalStyles)
            if style?.rubyType == .container { return current }
            node = current.parent
        }
        return nil
    }

    /// The first ruby text element in the node, depth first.
    private func rubyTextNode(globalStyles: [String: TtmlStyle]) -> TtmlNode? {
        let style = TtmlStyle.resolve(style, styleIds: styleIds, globalStyles: globalStyles)
        if style?.rubyType == .text { return self }
        for child in children {
            if let textNode = child.rubyTextNode(globalStyles: globalStyles) { return textNode }
        }
        return nil
    }
}

private extension TtmlNode {
    /// The text of the cue of a region as it is built, with what it shows.
    struct RegionOutput {
        var text = AttributedString()
        var textAlignment: Cue.Alignment?
        var multiRowAlignment: Cue.Alignment?
        var shearDegrees: CGFloat = 0

        /// The length in Unicode scalars, which the ranges of elements count.
        var length: Int { text.unicodeScalars.count }
    }

    /// An element that showed, and the lengths of the region outputs before and after its text.
    struct StyledNode {
        let node: TtmlNode
        let regionId: String
        let starts: [String: Int]
        var ends: [String: Int] = [:]
    }

    /// Text of ruby markup that only annotates: ruby text and delimiters.
    enum TtmlDeletedTextAttribute: AttributedStringKey {
        typealias Value = Bool
        static let name = "SEPlayerTtmlDeletedText"
    }

    /// The white space handling of TTML text: line feeds are spaces, and each run of white space is one space.
    static func applyingSpacePolicy(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var isAfterWhiteSpace = false
        for scalar in text.unicodeScalars {
            if whiteSpace.contains(scalar) {
                isAfterWhiteSpace = true
                continue
            }
            if isAfterWhiteSpace { result.append(" ") }
            isAfterWhiteSpace = false
            result.append(scalar)
        }
        if isAfterWhiteSpace { result.append(" ") }
        return String(result)
    }

    static let whiteSpace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]

    /// Ends the line at the end of a paragraph, unless it has nothing but spaces.
    static func endParagraph(_ text: inout AttributedString) {
        let lastCharacter = text.unicodeScalars.reversed().first { $0 != " " }
        if let lastCharacter, lastCharacter != "\n" {
            text.append(AttributedString("\n"))
        }
    }

    /// The text without the ruby annotations, spaces at the start and end of its lines and runs of spaces, and a line
    /// break at its end.
    static func cleanedUp(_ text: AttributedString) -> AttributedString {
        var kept = AttributedString()
        for run in text.runs where run[TtmlDeletedTextAttribute.self] != true {
            kept.append(text[run.range])
        }

        let scalars = Array(kept.unicodeScalars)
        // A run of spaces is one space, and lines don't start with one.
        var indices: [Int] = []
        for index in scalars.indices {
            let previous = indices.last.map { scalars[$0] }
            if scalars[index] == " ", previous == nil || previous == " " || previous == "\n" { continue }
            indices.append(index)
        }
        // Nor end with one.
        var reversedIndices: [Int] = []
        for index in indices.reversed() {
            let next = reversedIndices.last.map { scalars[$0] }
            if scalars[index] == " ", next == nil || next == "\n" { continue }
            reversedIndices.append(index)
        }
        if reversedIndices.first.map({ scalars[$0] }) == "\n" {
            reversedIndices.removeFirst()
        }

        let keptIndices = Set(reversedIndices)
        var result = AttributedString()
        var offset = 0
        for run in kept.runs {
            var runText = String.UnicodeScalarView()
            for scalar in kept[run.range].unicodeScalars {
                if keptIndices.contains(offset) { runText.append(scalar) }
                offset += 1
            }
            if !runText.isEmpty {
                result.append(AttributedString(String(runText), attributes: run.attributes))
            }
        }
        return result
    }

    /// Scales the relative font size of each run in the range, which the elements around it may have set to different
    /// sizes: unlike the other attributes, it can't be one value set over the range.
    static func scaleRelativeFontSize(
        of text: inout AttributedString,
        range: Range<AttributedString.Index>,
        by scale: CGFloat
    ) {
        let runs = text[range].runs.map { ($0.range, $0.cueRelativeFontSize ?? 1) }
        for (runRange, size) in runs {
            text[runRange].cueRelativeFontSize = size * scale
        }
    }

    /// The range of `text` between two Unicode scalar offsets.
    static func range(of text: AttributedString, scalars range: Range<Int>) -> Range<AttributedString.Index> {
        let scalars = text.unicodeScalars
        let lowerBound = scalars.index(scalars.startIndex, offsetBy: range.lowerBound)
        return lowerBound ..< scalars.index(lowerBound, offsetBy: range.count)
    }
}

/// The names of the TTML elements the parser reads.
enum TtmlTag {
    static let tt = "tt"
    static let head = "head"
    static let body = "body"
    static let division = "div"
    static let paragraph = "p"
    static let span = "span"
    static let lineBreak = "br"
    static let style = "style"
    static let styling = "styling"
    static let layout = "layout"
    static let region = "region"
    static let metadata = "metadata"
    static let image = "image"
    static let data = "data"
    static let information = "information"
}
