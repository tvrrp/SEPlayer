//
//  TextCodec.swift
//  SEPlayer
//

import Foundation

/// A format of timed text, named by its MIME type, with its attributes: `codec.cea608.channel`,
/// `codec.dvbSubtitle.compositionPageID`.
@dynamicMemberLookup
public struct TextCodec: Hashable, Sendable, CustomStringConvertible, CodecStorage {
    /// The scopes of the formats that have attributes.
    public struct Scopes {
        public let webVTT = WebVTT.self
        public let tx3g = TX3G.self
        public let cea608 = CEA608.self
        public let cea708 = CEA708.self
        public let dvbSubtitle = DVBSubtitle.self
        public let vobSub = VobSub.self
        public let cues = Cues.self
    }

    public var mimeType: MimeTypes

    public var description: String { codecDescription }

    var storage = AttributeStorage()

    public init(_ mimeType: MimeTypes) {
        self.mimeType = mimeType
    }

    /// A format of `mimeType` with the attributes of one scope.
    public init<S: FormatAttributeScope>(
        _ mimeType: MimeTypes,
        _ scope: KeyPath<Scopes, S.Type>,
        _ configure: (inout CodecAttributes<S>) throws -> Void
    ) rethrows {
        self.init(mimeType)
        try setAttributes(CodecAttributes<S>(configure))
    }

    public subscript<S: FormatAttributeScope>(dynamicMember keyPath: KeyPath<Scopes, S.Type>) -> CodecAttributes<S> {
        get { attributes(S.self) }
        set { setAttributes(newValue) }
    }
}

public extension TextCodec {
    struct WebVTT: FormatAttributeScope {
        /// The header of the file, which a `vttC` box repeats.
        public let header = FormatAttribute<String>("header")

        public init() {}
    }

    /// 3GPP timed text: the defaults of its sample entry.
    struct TX3G: FormatAttributeScope {
        /// The sample entry from its display flags on: the default box, style and fonts.
        public let sampleEntry = FormatAttribute<Data>("sampleEntry")

        public init() {}
    }

    struct CEA608: FormatAttributeScope {
        /// 1 to 4, for CC1 to CC4.
        public let channel = FormatAttribute<Int>("channel")

        public init() {}
    }

    struct CEA708: FormatAttributeScope {
        public let serviceNumber = FormatAttribute<Int>("serviceNumber")

        public init() {}
    }

    struct DVBSubtitle: FormatAttributeScope {
        public let compositionPageID = FormatAttribute<Int>("compositionPageID")
        public let ancillaryPageID = FormatAttribute<Int>("ancillaryPageID")

        public init() {}
    }

    struct VobSub: FormatAttributeScope {
        /// The size of the frame the subtitles were drawn for.
        public let frameSize = FormatAttribute<VideoSize>("frameSize")
        /// Sixteen colours, each 0xRRGGBB.
        public let palette = FormatAttribute<[UInt32]>("palette")

        public init() {}
    }

    struct Cues: FormatAttributeScope {
        /// The format the cues were read from.
        public let source = FormatAttribute<MimeTypes>("source")

        public init() {}
    }
}
