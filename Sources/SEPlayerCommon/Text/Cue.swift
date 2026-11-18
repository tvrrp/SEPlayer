//
//  Cue.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import CoreGraphics
import Foundation

/// Contains information about a specific cue, including textual content and formatting data.
///
/// Unset values are `nil`.
/// This type shouldn't be extended. If a subtitle format needs additional fields, either they should be generic enough
/// to be added here, or the format-specific decoder should pass the information around in a sidecar object.
public struct Cue: Hashable, @unchecked Sendable {
    /// The cue text, or `nil` if this is an image cue. Note the text may be decorated with styling attributes, those
    /// of `AttributeScopes.CueAttributes`.
    public let text: AttributedString?

    /// The alignment of the cue text within the cue box, or `nil` if the alignment is undefined.
    public let textAlignment: Alignment?

    /// The alignment of multiple lines of text relative to the longest line, or `nil` if the alignment is undefined.
    public let multiRowAlignment: Alignment?

    /// The cue image, or `nil` if this is a text cue.
    public let image: CGImage?

    /// The position of the cue box within the viewport in the direction orthogonal to the writing direction (determined
    /// by `verticalType`), or `nil`. When set, the interpretation of the value depends on its case, see `Line`.
    ///
    /// The measurement direction depends on `verticalType`:
    /// - For `nil` (i.e. horizontal), this is the vertical position relative to the top of the viewport.
    /// - For `.leftToRight` this is the horizontal position relative to the left of the viewport.
    /// - For `.rightToLeft` this is the horizontal position relative to the right of the viewport.
    public let line: Line?

    /// The cue box anchor positioned by `line` when it is `.fraction`.
    ///
    /// For the normal case of horizontal text, `.start`, `.middle` and `.end` correspond to the top, middle and bottom of
    /// the cue box respectively.
    public let lineAnchor: Anchor?

    /// The fractional position of the `positionAnchor` of the cue box within the viewport in the direction orthogonal to
    /// `line`, or `nil`.
    ///
    /// The measurement direction depends on `verticalType`:
    /// - For `nil` (i.e. horizontal), this is the horizontal position relative to the left of the viewport. Note that
    ///   positioning is relative to the left of the viewport even in the case of right-to-left text.
    /// - For `.leftToRight` and `.rightToLeft` (i.e. vertical), this is the vertical position relative to the top of the
    ///   viewport.
    public let position: CGFloat?

    /// The cue box anchor positioned by `position`.
    ///
    /// For the normal case of horizontal text, `.start`, `.middle` and `.end` correspond to the left, middle and right of
    /// the cue box respectively.
    public let positionAnchor: Anchor?

    /// The size of the cue box in the writing direction specified as a fraction of the viewport size in that direction,
    /// or `nil`.
    public let size: CGFloat?

    /// The image height as a fraction of the viewport size, or `nil` if the image should be displayed at its natural
    /// height given the image dimensions and the specified `size`.
    public let imageHeight: CGFloat?

    /// The fill color of the window, or `nil` if it isn't set.
    public let windowColor: CGColor?

    /// The default text size and its type for this cue's text, or `nil` if this cue has no default text size.
    public let textSize: TextSize?

    /// The vertical formatting of this cue, or `nil` if the cue has no vertical setting (and so should be horizontal).
    public let verticalType: VerticalType?

    /// The shear angle in degrees to be applied to this cue, expressed in graphics coordinates. This results in a skew
    /// transform for the block along the inline progression axis.
    public let shearDegrees: CGFloat

    /// The Z index for cue, the larger index will render above the smaller index. May be negative.
    public let zIndex: Int

    init(builder: Builder) {
        // Exactly one of text or image should be set.
        precondition((builder.text == nil) != (builder.image == nil), "Exactly one of text or image must be set")
        text = builder.text
        textAlignment = builder.textAlignment
        multiRowAlignment = builder.multiRowAlignment
        image = builder.image
        line = builder.line
        lineAnchor = builder.lineAnchor
        position = builder.position
        positionAnchor = builder.positionAnchor
        size = builder.size
        imageHeight = builder.imageHeight
        windowColor = builder.windowColor
        textSize = builder.textSize
        verticalType = builder.verticalType
        shearDegrees = builder.shearDegrees
        zIndex = builder.zIndex
    }

    /// Returns a new `Cue.Builder` initialized with the same values as this cue.
    public func buildUpon() -> Builder {
        Builder(cue: self)
    }
}

public extension Cue {
    /// The alignment of text, named as `NSTextAlignment`.
    enum Alignment: UInt8, Hashable, Sendable {
        /// `ALIGN_NORMAL`: the start of the writing direction.
        case leading = 0
        /// `ALIGN_CENTER`.
        case center = 1
        /// `ALIGN_OPPOSITE`: the end of the writing direction.
        case trailing = 2
    }

    /// The type of anchor.
    enum Anchor: UInt8, Hashable, Sendable {
        /// Anchors the left (for horizontal positions) or top (for vertical positions) edge of the cue box.
        case start = 0
        /// Anchors the middle of the cue box.
        case middle = 1
        /// Anchors the right (for horizontal positions) or bottom (for vertical positions) edge of the cue box.
        case end = 2
    }

    /// The value of `Cue.line`, with its type.
    enum Line: Hashable, Sendable {
        /// A fractional position within the viewport (measured to the part of the cue box determined by `lineAnchor`).
        case fraction(CGFloat)

        /// A viewport line number. The viewport is divided into lines (each equal in size to the first line of the cue
        /// box). The cue box is positioned to align with the viewport lines as follows:
        /// - `lineAnchor` is ignored.
        /// - When the number is greater than or equal to 0 the first line in the cue box is aligned with a viewport line,
        ///   with 0 meaning the first line of the viewport.
        /// - When the number is negative the last line in the cue box is aligned with a viewport line, with -1 meaning
        ///   the last line of the viewport.
        /// - For horizontal text the start and end of the viewport are the top and bottom respectively.
        case number(Int)
    }

    /// The default text size, with its type.
    enum TextSize: Hashable, Sendable {
        /// Text size is measured as a fraction of the viewport size minus the view padding.
        case fractional(CGFloat)
        /// Text size is measured as a fraction of the viewport size, ignoring the view padding.
        case fractionalIgnoringPadding(CGFloat)
        /// Text size is measured in points.
        case absolute(CGFloat)
    }

    /// The type of vertical layout.
    enum VerticalType: UInt8, Hashable, Sendable {
        /// Vertical right-to-left (e.g. for Japanese).
        case rightToLeft = 1
        /// Vertical left-to-right (e.g. for Mongolian).
        case leftToRight = 2
    }

    /// A builder for `Cue` objects.
    final class Builder {
        public private(set) var text: AttributedString?
        public private(set) var image: CGImage?
        public private(set) var textAlignment: Alignment?
        public private(set) var multiRowAlignment: Alignment?
        public private(set) var line: Line?
        public private(set) var lineAnchor: Anchor?
        public private(set) var position: CGFloat?
        public private(set) var positionAnchor: Anchor?
        public private(set) var size: CGFloat?
        public private(set) var imageHeight: CGFloat?
        public private(set) var windowColor: CGColor?
        public private(set) var textSize: TextSize?
        public private(set) var verticalType: VerticalType?
        public private(set) var shearDegrees: CGFloat = 0
        public private(set) var zIndex: Int = 0

        public init() {}

        init(cue: Cue) {
            text = cue.text
            image = cue.image
            textAlignment = cue.textAlignment
            multiRowAlignment = cue.multiRowAlignment
            line = cue.line
            lineAnchor = cue.lineAnchor
            position = cue.position
            positionAnchor = cue.positionAnchor
            size = cue.size
            imageHeight = cue.imageHeight
            windowColor = cue.windowColor
            textSize = cue.textSize
            verticalType = cue.verticalType
            shearDegrees = cue.shearDegrees
            zIndex = cue.zIndex
        }

        /// Builds the cue.
        public func build() -> Cue {
            Cue(builder: self)
        }

        /// Sets the text, and clears the image.
        /// Sets the cue text.
        ///
        /// Note that `text` may be decorated with styling attributes.
        ///
        /// Note that this will also set the `image` to `nil`.
        @discardableResult
        public func setText(_ text: AttributedString) -> Builder {
            self.text = text
            image = nil
            return self
        }

        /// Sets the text, and clears the image.
        /// Sets the cue text.
        ///
        /// Note that this will also set the `image` to `nil`.
        @discardableResult
        public func setText(_ text: String) -> Builder {
            setText(AttributedString(text))
        }

        /// Sets the image, and clears the text.
        /// Sets the cue image.
        ///
        /// Note that this will also set the `text` to `nil`.
        @discardableResult
        public func setImage(_ image: CGImage) -> Builder {
            self.image = image
            text = nil
            return self
        }

        /// Sets the alignment of the cue text within the cue box.
        ///
        /// Passing `nil` means the alignment is undefined.
        @discardableResult
        public func setTextAlignment(_ textAlignment: Alignment?) -> Builder {
            self.textAlignment = textAlignment
            return self
        }

        /// Sets the multi-row alignment of the cue.
        ///
        /// Passing `nil` means the alignment is undefined.
        @discardableResult
        public func setMultiRowAlignment(_ multiRowAlignment: Alignment?) -> Builder {
            self.multiRowAlignment = multiRowAlignment
            return self
        }

        /// Sets the position of the cue box within the viewport in the direction orthogonal to the writing direction.
        @discardableResult
        public func setLine(_ line: Line?) -> Builder {
            self.line = line
            return self
        }

        /// Sets the cue box anchor positioned by `line`.
        @discardableResult
        public func setLineAnchor(_ lineAnchor: Anchor?) -> Builder {
            self.lineAnchor = lineAnchor
            return self
        }

        /// Sets the fractional position of the `positionAnchor` of the cue box within the viewport in the direction
        /// orthogonal to `line`.
        @discardableResult
        public func setPosition(_ position: CGFloat?) -> Builder {
            self.position = position
            return self
        }

        /// Sets the cue box anchor positioned by `position`.
        @discardableResult
        public func setPositionAnchor(_ positionAnchor: Anchor?) -> Builder {
            self.positionAnchor = positionAnchor
            return self
        }

        /// Sets the size of the cue box in the writing direction specified as a fraction of the viewport size in that
        /// direction.
        @discardableResult
        public func setSize(_ size: CGFloat?) -> Builder {
            self.size = size
            return self
        }

        /// Sets the image height as a fraction of the viewport size.
        @discardableResult
        public func setImageHeight(_ imageHeight: CGFloat?) -> Builder {
            self.imageHeight = imageHeight
            return self
        }

        /// Sets the fill color of the window. `nil` clears it.
        @discardableResult
        public func setWindowColor(_ windowColor: CGColor?) -> Builder {
            self.windowColor = windowColor
            return self
        }

        /// Sets the default text size and type for this cue's text.
        @discardableResult
        public func setTextSize(_ textSize: TextSize?) -> Builder {
            self.textSize = textSize
            return self
        }

        /// Sets the vertical formatting for this cue.
        @discardableResult
        public func setVerticalType(_ verticalType: VerticalType?) -> Builder {
            self.verticalType = verticalType
            return self
        }

        /// Sets the shear angle for this cue.
        @discardableResult
        public func setShearDegrees(_ shearDegrees: CGFloat) -> Builder {
            self.shearDegrees = shearDegrees
            return self
        }

        /// Sets the zIndex for this cue.
        @discardableResult
        public func setZIndex(_ zIndex: Int) -> Builder {
            self.zIndex = zIndex
            return self
        }
    }
}
