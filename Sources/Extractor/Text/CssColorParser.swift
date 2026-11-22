//
//  CssColorParser.swift
//  SEPlayer
//

import CoreGraphics
import Foundation

/// Parses CSS and TTML colors: `#rrggbb`, `#rrggbbaa`, `#rgb`, `rgb()`, `rgba()` and color names.
enum CssColorParser {
    static func parseCssColor(_ value: String) -> CGColor? {
        parseColor(value, isAlphaFraction: true)
    }

    /// A TTML color, whose `rgba()` alpha is from 0 to 255.
    static func parseTtmlColor(_ value: String) -> CGColor? {
        parseColor(value, isAlphaFraction: false)
    }

    private static func parseColor(_ value: String, isAlphaFraction: Bool) -> CGColor? {
        let value = value.replacingOccurrences(of: " ", with: "").lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("#") {
            return parseHex(value.dropFirst())
        }
        if value.hasPrefix("rgba(") || value.hasPrefix("rgb("), value.hasSuffix(")") {
            let isRgba = value.hasPrefix("rgba(")
            let arguments = value.dropFirst(isRgba ? 5 : 4).dropLast().split(separator: ",")
            guard arguments.count == (isRgba ? 4 : 3) else { return nil }
            let channels = arguments.prefix(3).compactMap { Double($0) }
            guard channels.count == 3 else { return nil }
            // The alpha of CSS colors is a fraction.
            let alpha = isRgba ? Double(arguments[3]).map { isAlphaFraction ? $0 : $0 / 255 } : 1
            guard let alpha else { return nil }
            return makeColor(red: channels[0] / 255, green: channels[1] / 255, blue: channels[2] / 255, alpha: alpha)
        }
        return namedColors[value].map { makeColor(rgb: $0, alpha: 1) }
    }

    private static func parseHex(_ hex: Substring) -> CGColor? {
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        switch hex.count {
        case 3:
            // #rgb: each digit doubled.
            let expanded = hex.map { "\($0)\($0)" }.joined()
            return UInt32(expanded, radix: 16).map { makeColor(rgb: $0, alpha: 1) }
        case 6:
            return UInt32(hex, radix: 16).map { makeColor(rgb: $0, alpha: 1) }
        case 8:
            // CSS puts alpha last.
            guard let rgba = UInt32(hex, radix: 16) else { return nil }
            return makeColor(rgb: rgba >> 8, alpha: Double(rgba & 0xFF) / 255)
        default:
            return nil
        }
    }

    private static func makeColor(rgb: UInt32, alpha: Double) -> CGColor {
        makeColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func makeColor(red: Double, green: Double, blue: Double, alpha: Double) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static let namedColors: [String: UInt32] = [
        "aqua": 0x00FFFF, "black": 0x000000, "blue": 0x0000FF, "brown": 0xA52A2A, "cyan": 0x00FFFF,
        "darkblue": 0x00008B, "darkgray": 0xA9A9A9, "darkgreen": 0x006400, "darkgrey": 0xA9A9A9,
        "darkred": 0x8B0000, "fuchsia": 0xFF00FF, "gold": 0xFFD700, "gray": 0x808080, "green": 0x008000,
        "grey": 0x808080, "indigo": 0x4B0082, "lightblue": 0xADD8E6, "lightgray": 0xD3D3D3,
        "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightyellow": 0xFFFFE0, "lime": 0x00FF00,
        "magenta": 0xFF00FF, "maroon": 0x800000, "navy": 0x000080, "olive": 0x808000, "orange": 0xFFA500,
        "pink": 0xFFC0CB, "purple": 0x800080, "red": 0xFF0000, "silver": 0xC0C0C0, "teal": 0x008080,
        "violet": 0xEE82EE, "white": 0xFFFFFF, "yellow": 0xFFFF00,
    ]
}
