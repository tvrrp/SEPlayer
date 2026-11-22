//
//  CaptionStyle.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.ui.CaptionStyleCompat
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics
import CoreText
#if canImport(MediaAccessibility)
import MediaAccessibility
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A style for subtitles, made from the user's settings in Settings › Accessibility ›
/// Subtitles & Captioning.
///
/// Each value says whether it overrides the styles embedded in the cues: the user can ask for their choice to win.
public struct CaptionStyle: @unchecked Sendable {
    /// The type of edge, as `MACaptionAppearanceTextEdgeStyle`.
    public enum EdgeType: Sendable {
        /// Edge type value specifying no character edges.
        case none
        /// Edge type value specifying uniformly outlined character edges.
        case outline
        /// Edge type value specifying drop-shadowed character edges.
        case dropShadow
        /// Edge type value specifying raised bevel character edges.
        case raised
        /// Edge type value specifying depressed bevel character edges.
        case depressed
    }

    /// The preferred foreground color.
    public var foregroundColor: CGColor
    /// The preferred background color.
    public var backgroundColor: CGColor
    /// The preferred window color.
    public var windowColor: CGColor
    /// How the window wraps the text.
    public var windowMetrics: WindowMetrics
    /// The preferred edge type.
    public var edgeType: EdgeType
    /// The preferred edge color, if using an edge type other than `.none`.
    public var edgeColor: CGColor
    /// The preferred font, or `nil` for the system font.
    public var fontDescriptor: CTFontDescriptor?
    /// How much larger than the default the text is.
    public var relativeCharacterSize: CGFloat

    /// Whether `foregroundColor` replaces the text colors of the cues.
    public var overridesForegroundColor: Bool
    /// Whether `backgroundColor` replaces the background colors of the cues.
    public var overridesBackgroundColor: Bool
    /// Whether `windowColor` replaces the window colors of the cues.
    public var overridesWindowColor: Bool
    /// Whether `fontDescriptor` replaces the fonts of the cues.
    public var overridesFont: Bool
    /// Whether `relativeCharacterSize` replaces the text sizes of the cues.
    public var overridesTextSize: Bool

    public init(
        foregroundColor: CGColor,
        backgroundColor: CGColor,
        windowColor: CGColor,
        windowMetrics: WindowMetrics = .standard,
        edgeType: EdgeType,
        edgeColor: CGColor,
        fontDescriptor: CTFontDescriptor? = nil,
        relativeCharacterSize: CGFloat = 1,
        overridesForegroundColor: Bool = false,
        overridesBackgroundColor: Bool = false,
        overridesWindowColor: Bool = false,
        overridesFont: Bool = false,
        overridesTextSize: Bool = false
    ) {
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.windowColor = windowColor
        self.windowMetrics = windowMetrics
        self.edgeType = edgeType
        self.edgeColor = edgeColor
        self.fontDescriptor = fontDescriptor
        self.relativeCharacterSize = relativeCharacterSize
        self.overridesForegroundColor = overridesForegroundColor
        self.overridesBackgroundColor = overridesBackgroundColor
        self.overridesWindowColor = overridesWindowColor
        self.overridesFont = overridesFont
        self.overridesTextSize = overridesTextSize
    }

    /// The style the system starts with: white text in the medium system font, in a black window at half opacity,
    /// with no edges.
    public static let `default` = CaptionStyle(
        foregroundColor: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        backgroundColor: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
        windowColor: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5),
        windowMetrics: .standard,
        edgeType: .none,
        edgeColor: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        fontDescriptor: mediumSystemFontDescriptor
    )

    /// The system font in medium weight, which captions use unless the user picks another.
    private static var mediumSystemFontDescriptor: CTFontDescriptor? {
        #if canImport(UIKit)
        UIFont.systemFont(ofSize: 17, weight: .medium).fontDescriptor as CTFontDescriptor
        #elseif canImport(AppKit)
        NSFont.systemFont(ofSize: 17, weight: .medium).fontDescriptor as CTFontDescriptor
        #else
        nil
        #endif
    }

    /// The style the user chose in the system settings.
    public static var user: CaptionStyle {
        #if canImport(MediaAccessibility)
        let domain = MACaptionAppearanceDomain.user
        var behavior = MACaptionAppearanceBehavior.useContentIfAvailable

        let foregroundColor = MACaptionAppearanceCopyForegroundColor(domain, &behavior).takeRetainedValue()
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(domain, nil)
        let overridesForegroundColor = behavior == .useValue

        let backgroundColor = MACaptionAppearanceCopyBackgroundColor(domain, &behavior).takeRetainedValue()
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(domain, nil)
        let overridesBackgroundColor = behavior == .useValue

        let windowColor = MACaptionAppearanceCopyWindowColor(domain, &behavior).takeRetainedValue()
        let windowOpacity = MACaptionAppearanceGetWindowOpacity(domain, nil)
        let overridesWindowColor = behavior == .useValue

        let fontDescriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, &behavior, .default).takeRetainedValue()
        let overridesFont = behavior == .useValue

        let relativeCharacterSize = MACaptionAppearanceGetRelativeCharacterSize(domain, &behavior)
        let overridesTextSize = behavior == .useValue

        let edgeType: EdgeType = switch MACaptionAppearanceGetTextEdgeStyle(domain, nil) {
        case .uniform: .outline
        case .dropShadow: .dropShadow
        case .raised: .raised
        case .depressed: .depressed
        default: .none
        }

        let characterSize = relativeCharacterSize > 0 ? relativeCharacterSize : 1
        return CaptionStyle(
            foregroundColor: foregroundColor.copy(alpha: foregroundOpacity) ?? foregroundColor,
            backgroundColor: backgroundColor.copy(alpha: backgroundOpacity) ?? backgroundColor,
            windowColor: windowColor.copy(alpha: windowOpacity) ?? windowColor,
            windowMetrics: .forStyle(
                backgroundOpacity: backgroundOpacity,
                windowOpacity: windowOpacity,
                edgeType: edgeType,
                relativeCharacterSize: characterSize
            ),
            edgeType: edgeType,
            edgeColor: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            fontDescriptor: fontDescriptor,
            relativeCharacterSize: characterSize,
            overridesForegroundColor: overridesForegroundColor,
            overridesBackgroundColor: overridesBackgroundColor,
            overridesWindowColor: overridesWindowColor,
            overridesFont: overridesFont,
            overridesTextSize: overridesTextSize
        )
        #else
        return .default
        #endif
    }
}

public extension CaptionStyle {
    /// How the window wraps the text of a cue, in fractions of the font size: the window is the text and its padding,
    /// half of it on each side, with corners of the radius.
    struct WindowMetrics: Hashable, Sendable {
        /// The padding left and right of the text together.
        public var horizontalPadding: CGFloat
        /// The padding above and below the text together.
        public var verticalPadding: CGFloat
        /// The radius of the corners.
        public var cornerRadius: CGFloat

        public init(horizontalPadding: CGFloat, verticalPadding: CGFloat, cornerRadius: CGFloat) {
            self.horizontalPadding = horizontalPadding
            self.verticalPadding = verticalPadding
            self.cornerRadius = cornerRadius
        }

        /// The window of the style the system starts with, Transparent Background.
        public static let standard = WindowMetrics(horizontalPadding: 0.7, verticalPadding: 0.11, cornerRadius: 0.35)
        /// The window of the Large Text style.
        public static let largeText = WindowMetrics(horizontalPadding: 0.59, verticalPadding: 0.07, cornerRadius: 0.15)
        /// The padding of the Classic style, whose text has a background instead of a window.
        public static let classic = WindowMetrics(horizontalPadding: 0.53, verticalPadding: 0.26, cornerRadius: 0.26)
        /// The padding of the Outline Text style, which has no window.
        public static let outlineText = WindowMetrics(horizontalPadding: 0.59, verticalPadding: 0, cornerRadius: 0)
        /// The window of a style the user made.
        public static let custom = WindowMetrics(horizontalPadding: 0.77, verticalPadding: 0.1, cornerRadius: 0.23)

        /// The window of the style with these settings: the system's styles are told apart by them, any other style is
        /// one the user made.
        static func forStyle(
            backgroundOpacity: CGFloat,
            windowOpacity: CGFloat,
            edgeType: EdgeType,
            relativeCharacterSize: CGFloat
        ) -> WindowMetrics {
            let hasBackground = backgroundOpacity > 0
            let hasWindow = windowOpacity > 0
            switch (hasBackground, hasWindow, edgeType) {
            case (false, false, .outline) where relativeCharacterSize == 1.5: return .outlineText
            case (true, false, .none) where backgroundOpacity == 1 && relativeCharacterSize == 1: return .classic
            case (false, true, .none) where windowOpacity == 0.5 && relativeCharacterSize == 1: return .standard
            case (false, true, .none) where windowOpacity == 0.5 && relativeCharacterSize == 1.5: return .largeText
            default: return .custom
            }
        }
    }
}
