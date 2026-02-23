//
//  RendererCapabilities.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

public enum RendererCapabilities {
    public struct Support {
        let formatSupport: FormatSupport
        let adaptiveSupport: AdaptiveSupport
        let hardwareAccelerationSupport: HardwareAccelerationSupport
        let decoderSupport: DecoderSupport
        let tunnelingSupport: TunnelingSupport

        public enum FormatSupport: Comparable {
            case unsupportedType
            case unsupportedSubtype
            case unsupportedDrm
            case exceedCapabilities
            case handled
        }

        public struct AdaptiveSupport: OptionSet {
            public let rawValue: Int
            public init(rawValue: Int) {
                self.rawValue = rawValue
            }

            public static let seamless = AdaptiveSupport(rawValue: 1 << 3)
            public static let notSeamless = AdaptiveSupport(rawValue: 1 << 2)
            public static let notSupported = AdaptiveSupport(rawValue: 1 << 0)
        }

        public enum HardwareAccelerationSupport {
            case supported
            case notSupported
        }

        public enum DecoderSupport {
            case fallbackMimeType
            case primary
            case fallback
        }

        public enum TunnelingSupport {
            case supported
            case notSupported
        }

        public init(
            formatSupport: FormatSupport,
            adaptiveSupport: AdaptiveSupport,
            hardwareAccelerationSupport: HardwareAccelerationSupport,
            decoderSupport: DecoderSupport,
            tunnelingSupport: TunnelingSupport
        ) {
            self.formatSupport = formatSupport
            self.adaptiveSupport = adaptiveSupport
            self.hardwareAccelerationSupport = hardwareAccelerationSupport
            self.decoderSupport = decoderSupport
            self.tunnelingSupport = tunnelingSupport
        }

        public init() {
            self = Self.create(formatSupport: .unsupportedType)
        }

        public func isFormatSupported(allowExceedsCapabilities: Bool) -> Bool {
            formatSupport == .handled || (allowExceedsCapabilities && formatSupport == .exceedCapabilities)
        }

        public static func create(formatSupport: FormatSupport) -> Support {
            create(
                formatSupport: formatSupport,
                adaptiveSupport: .notSupported,
                tunnelingSupport: .notSupported
            )
        }

        public static func create(
            formatSupport: FormatSupport,
            adaptiveSupport: AdaptiveSupport,
        ) -> Support {
            self.init(
                formatSupport: formatSupport,
                adaptiveSupport: adaptiveSupport,
                hardwareAccelerationSupport: .notSupported,
                decoderSupport: .primary,
                tunnelingSupport: .notSupported
            )
        }

        public static func create(
            formatSupport: FormatSupport,
            adaptiveSupport: AdaptiveSupport,
            tunnelingSupport: TunnelingSupport
        ) -> Support {
            self.init(
                formatSupport: formatSupport,
                adaptiveSupport: adaptiveSupport,
                hardwareAccelerationSupport: .notSupported,
                decoderSupport: .primary,
                tunnelingSupport: tunnelingSupport
            )
        }

        public static func create(
            formatSupport: FormatSupport,
            adaptiveSupport: AdaptiveSupport,
            hardwareAccelerationSupport: HardwareAccelerationSupport,
            decoderSupport: DecoderSupport,
        ) -> Support {
            self.init(
                formatSupport: formatSupport,
                adaptiveSupport: adaptiveSupport,
                hardwareAccelerationSupport: hardwareAccelerationSupport,
                decoderSupport: decoderSupport,
                tunnelingSupport: .notSupported
            )
        }
    }
}

public protocol RendererCapabilitiesResolver: AnyObject {
    var name: String { get }
    var trackType: TrackType { get }
    var listener: RendererCapabilitiesListener? { get set }
    func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support
    func supportsMixedMimeTypeAdaptation() throws -> RendererCapabilities.Support.AdaptiveSupport
}

public protocol RendererCapabilitiesListener: AnyObject {
    func onRendererCapabilitiesChanged(_ renderer: SERenderer)
}
