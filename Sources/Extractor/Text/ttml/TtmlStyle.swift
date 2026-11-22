//
//  TtmlStyle.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.ttml.TtmlStyle
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics
import SEPlayerCommon

/// The style attributes of a TTML element or of a `style` element. Unset attributes are `nil`.
struct TtmlStyle {
    enum FontSize {
        case pixels(CGFloat)
        case em(CGFloat)
        /// A percentage of the font size of the parent.
        case percent(CGFloat)
    }

    /// The part of ruby markup an element is.
    enum RubyType {
        case container
        case base
        case text
        case delimiter
    }

    var id: String?
    var fontFamily: String?
    var fontColor: CGColor?
    var backgroundColor: CGColor?
    var isLinethrough: Bool?
    var isUnderline: Bool?
    var isBold: Bool?
    var isItalic: Bool?
    var fontSize: FontSize?
    var rubyType: RubyType?
    var rubyPosition: Cue.AnnotationPosition?
    var textAlign: Cue.Alignment?
    var multiRowAlign: Cue.Alignment?
    /// Whether the text is set horizontally in vertical text: `tts:textCombine="all"`.
    var textCombine: Bool?
    var textEmphasis: TtmlTextEmphasis?
    /// From -100 to 100.
    var shearPercentage: CGFloat?
    var origin: String?
    var extent: String?
    var displayAlign: String?

    /// The style with the attributes of `ancestor` it doesn't set itself. Unlike ``inheriting(from:)``, also takes
    /// the attributes that aren't inherited, for a style that refers to another.
    func chained(to ancestor: TtmlStyle?) -> TtmlStyle {
        inheriting(from: ancestor, chaining: true)
    }

    /// The style with the inheritable attributes of `ancestor` it doesn't set itself.
    func inheriting(from ancestor: TtmlStyle?) -> TtmlStyle {
        inheriting(from: ancestor, chaining: false)
    }

    /// The style of an element: its own attributes over those of the styles it refers to, in order.
    static func resolve(_ style: TtmlStyle?, styleIds: [String], globalStyles: [String: TtmlStyle]) -> TtmlStyle? {
        guard style != nil || !styleIds.isEmpty else { return nil }
        if style == nil, styleIds.count == 1 {
            return globalStyles[styleIds[0]]
        }
        return styleIds.reduce(style ?? TtmlStyle()) { $0.chained(to: globalStyles[$1]) }
    }

    private func inheriting(from ancestor: TtmlStyle?, chaining: Bool) -> TtmlStyle {
        guard let ancestor else { return self }
        var style = self
        style.fontColor = fontColor ?? ancestor.fontColor
        style.isBold = isBold ?? ancestor.isBold
        style.isItalic = isItalic ?? ancestor.isItalic
        style.fontFamily = fontFamily ?? ancestor.fontFamily
        style.isLinethrough = isLinethrough ?? ancestor.isLinethrough
        style.isUnderline = isUnderline ?? ancestor.isUnderline
        style.rubyPosition = rubyPosition ?? ancestor.rubyPosition
        style.textAlign = textAlign ?? ancestor.textAlign
        style.multiRowAlign = multiRowAlign ?? ancestor.multiRowAlign
        style.textCombine = textCombine ?? ancestor.textCombine
        style.fontSize = fontSize ?? ancestor.fontSize
        style.textEmphasis = textEmphasis ?? ancestor.textEmphasis
        style.shearPercentage = shearPercentage ?? ancestor.shearPercentage
        style.origin = origin ?? ancestor.origin
        style.extent = extent ?? ancestor.extent
        style.displayAlign = displayAlign ?? ancestor.displayAlign
        // TTML doesn't inherit these.
        if chaining {
            style.backgroundColor = backgroundColor ?? ancestor.backgroundColor
            style.rubyType = rubyType ?? ancestor.rubyType
        }
        return style
    }
}

/// The emphasis marks of `tts:textEmphasis`, with the values only TTML has: `auto` and `outside`.
struct TtmlTextEmphasis {
    enum MarkShape {
        case none
        /// A sesame in vertical text, a circle otherwise.
        case auto
        case circle
        case dot
        case sesame
    }

    enum Position {
        case before
        case after
        /// Before, for marks.
        case outside
    }

    let markShape: MarkShape
    let markFill: Cue.TextEmphasis.MarkFill?
    let position: Position

    /// Reads the shape, fill and position words of the attribute, in any order. Words it doesn't know are ignored;
    /// without a shape or a fill it is `auto`, and without a position, `outside`.
    init?(_ value: String) {
        let words = Set(value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        guard !words.isEmpty else { return nil }

        position = if words.contains("after") {
            .after
        } else if words.contains("before") {
            .before
        } else {
            .outside
        }

        // `auto` and `none` leave out the other words.
        if words.contains("auto") {
            markShape = .auto
            markFill = nil
            return
        }
        if words.contains("none") {
            markShape = .none
            markFill = nil
            return
        }
        let shape: MarkShape? = if words.contains("dot") {
            .dot
        } else if words.contains("sesame") {
            .sesame
        } else if words.contains("circle") {
            .circle
        } else {
            nil
        }
        let fill: Cue.TextEmphasis.MarkFill? = if words.contains("filled") {
            .filled
        } else if words.contains("open") {
            .open
        } else {
            nil
        }
        guard shape != nil || fill != nil else {
            markShape = .auto
            markFill = nil
            return
        }
        markShape = shape ?? .circle
        markFill = fill ?? .filled
    }

    /// The marks to draw, for horizontal or vertical text.
    func resolved(isVertical: Bool) -> Cue.TextEmphasis {
        let shape: Cue.TextEmphasis.MarkShape
        let fill: Cue.TextEmphasis.MarkFill?
        switch markShape {
        case .auto:
            shape = isVertical ? .sesame : .circle
            fill = .filled
        case .none:
            shape = .none
            fill = markFill
        case .circle:
            shape = .circle
            fill = markFill
        case .dot:
            shape = .dot
            fill = markFill
        case .sesame:
            shape = .sesame
            fill = markFill
        }
        let position: Cue.AnnotationPosition = self.position == .after ? .after : .before
        return Cue.TextEmphasis(markShape: shape, markFill: fill, position: position)
    }
}

/// A region of a TTML document: where the cues of the elements in it show.
struct TtmlRegion {
    let id: String
    /// The left of the region, as a fraction of the width of the viewport.
    let position: CGFloat?
    /// Where the text is anchored vertically: the top, middle or bottom of the region, as `lineAnchor` says.
    let line: CGFloat?
    let lineAnchor: Cue.Anchor?
    /// The size of the region, as fractions of the viewport.
    let width: CGFloat?
    let height: CGFloat?
    /// The height of a cell, as a fraction of the height of the viewport.
    let textSize: CGFloat?
    let verticalType: Cue.VerticalType?

    /// The region of elements that name none, placed as cues are by default.
    static let anonymous = TtmlRegion(
        id: "",
        position: nil,
        line: nil,
        lineAnchor: nil,
        width: nil,
        height: nil,
        textSize: nil,
        verticalType: nil
    )
}
