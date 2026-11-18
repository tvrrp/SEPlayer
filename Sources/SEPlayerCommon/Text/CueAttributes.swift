//
//  CueAttributes.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//

import CoreGraphics
import Foundation

/// The styles of `Cue.text`, as attributes of an `AttributedString`.
///
/// Styles that depend on the font a renderer picks for the viewport, such as relative sizes, stay abstract: the renderer
/// resolves them when it draws.
public enum CueTextAttributes {
    /// The color of the text.
    public enum ForegroundColorAttribute: AttributedStringKey {
        public typealias Value = CGColor
        public static let name = "SEPlayerCueForegroundColor"
    }

    /// The color behind the text.
    public enum BackgroundColorAttribute: AttributedStringKey {
        public typealias Value = CGColor
        public static let name = "SEPlayerCueBackgroundColor"
    }

    /// Whether the text is underlined.
    public enum UnderlineAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "SEPlayerCueUnderline"
    }

    /// Whether the text is struck through.
    public enum StrikethroughAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "SEPlayerCueStrikethrough"
    }

    /// Whether the text is bold.
    public enum BoldAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "SEPlayerCueBold"
    }

    /// Whether the text is italic.
    public enum ItalicAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "SEPlayerCueItalic"
    }

    /// The font family, or a generic one, such as `serif` or `monospace`.
    public enum FontFamilyAttribute: AttributedStringKey {
        public typealias Value = String
        public static let name = "SEPlayerCueFontFamily"
    }

    /// The font size, proportional to the cue's text size.
    public enum RelativeFontSizeAttribute: AttributedStringKey {
        public typealias Value = CGFloat
        public static let name = "SEPlayerCueRelativeFontSize"
    }

    /// The font size in points.
    public enum AbsoluteFontSizeAttribute: AttributedStringKey {
        public typealias Value = CGFloat
        public static let name = "SEPlayerCueAbsoluteFontSize"
    }

    /// A styling span for ruby text.
    ///
    /// The text covered by this span is known as the "base text", and the ruby text is stored in `Cue.Ruby.text`.
    ///
    /// More information on [ruby characters](https://en.wikipedia.org/wiki/Ruby_character).
    public enum RubyAttribute: AttributedStringKey {
        public typealias Value = Cue.Ruby
        public static let name = "SEPlayerCueRuby"
    }

    /// A styling span for text emphasis marks.
    ///
    /// These are pronunciation aids such as [Japanese boutens](https://www.w3.org/TR/jlreq/?lang=en#term.emphasis-dots)
    /// which can be rendered using the [text-emphasis](https://developer.mozilla.org/en-US/docs/Web/CSS/text-emphasis)
    /// CSS property.
    public enum TextEmphasisAttribute: AttributedStringKey {
        public typealias Value = Cue.TextEmphasis
        public static let name = "SEPlayerCueTextEmphasis"
    }

    /// A styling span for horizontal text in a vertical context.
    ///
    /// This is used in vertical text to write some characters in a horizontal orientation, known in Japanese as
    /// tate-chu-yoko.
    ///
    /// More information on [tate-chu-yoko](https://www.w3.org/TR/jlreq/#handling_of_tatechuyoko).
    public enum HorizontalInVerticalAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "SEPlayerCueHorizontalInVertical"
    }

    /// A span representing the speaker of the spanned text, the voice name.
    ///
    /// For example a [WebVTT voice span](https://www.w3.org/TR/webvtt1/#webvtt-cue-voice-span).
    public enum VoiceAttribute: AttributedStringKey {
        public typealias Value = String
        public static let name = "SEPlayerCueVoice"
    }
}

public extension AttributeScopes {
    /// The attributes of cue text.
    struct CueAttributes: AttributeScope {
        public let cueForegroundColor: CueTextAttributes.ForegroundColorAttribute
        public let cueBackgroundColor: CueTextAttributes.BackgroundColorAttribute
        public let cueUnderline: CueTextAttributes.UnderlineAttribute
        public let cueStrikethrough: CueTextAttributes.StrikethroughAttribute
        public let cueBold: CueTextAttributes.BoldAttribute
        public let cueItalic: CueTextAttributes.ItalicAttribute
        public let cueFontFamily: CueTextAttributes.FontFamilyAttribute
        public let cueRelativeFontSize: CueTextAttributes.RelativeFontSizeAttribute
        public let cueAbsoluteFontSize: CueTextAttributes.AbsoluteFontSizeAttribute
        public let cueRuby: CueTextAttributes.RubyAttribute
        public let cueTextEmphasis: CueTextAttributes.TextEmphasisAttribute
        public let cueHorizontalInVertical: CueTextAttributes.HorizontalInVerticalAttribute
        public let cueVoice: CueTextAttributes.VoiceAttribute
    }

    var cue: CueAttributes.Type { CueAttributes.self }
}

public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.CueAttributes, T>) -> T {
        self[T.self]
    }
}

public extension Cue {
    /// The possible positions of the annotation text (i.e. ruby, text emphasis marks) relative to the base text.
    /// `nil` when the position is unknown.
    enum AnnotationPosition: UInt8, Hashable, Sendable {
        /// For horizontal text, the text annotation should be positioned above the base text.
        ///
        /// For vertical text it should be positioned to the right, same as CSS's
        /// [ruby-position](https://developer.mozilla.org/en-US/docs/Web/CSS/ruby-position).
        case before = 1
        /// For horizontal text, the text annotation should be positioned below the base text.
        ///
        /// For vertical text it should be positioned to the left, same as CSS's
        /// [ruby-position](https://developer.mozilla.org/en-US/docs/Web/CSS/ruby-position).
        case after = 2
    }

    /// Ruby text, the value of the `cueRuby` attribute.
    struct Ruby: Hashable, Sendable {
        /// The ruby text, i.e. the smaller explanatory characters.
        public let text: String
        /// The position of the ruby text relative to the base text.
        public let position: AnnotationPosition?

        public init(text: String, position: AnnotationPosition?) {
            self.text = text
            self.position = position
        }
    }

    /// Text emphasis marks, the value of the `cueTextEmphasis` attribute.
    struct TextEmphasis: Hashable, Sendable {
        /// The possible mark shapes that can be used.
        public enum MarkShape: UInt8, Hashable, Sendable {
            case none = 0
            case circle = 1
            case dot = 2
            case sesame = 3
        }

        /// The possible mark fills that can be used. `nil` when the fill is unknown.
        public enum MarkFill: UInt8, Hashable, Sendable {
            case filled = 1
            case open = 2
        }

        /// The mark shape used for text emphasis.
        public let markShape: MarkShape
        /// The mark fill for the text emphasis mark.
        public let markFill: MarkFill?
        /// The position of the text emphasis relative to the base text.
        public let position: AnnotationPosition?

        public init(markShape: MarkShape, markFill: MarkFill?, position: AnnotationPosition?) {
            self.markShape = markShape
            self.markFill = markFill
            self.position = position
        }
    }
}
