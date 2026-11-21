//
//  Format.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.06.2025.
//

/// What is known about a track: the attributes every track can have, and those of its kind of media.
///
/// `VideoFormat`, `AudioFormat`, `TextFormat` and `MetadataFormat` read the attributes of their media; an `AnyFormat`
/// reads the common ones and narrows to the format of its media.
@dynamicMemberLookup
public struct Format<Scope: FormatAttributeScope>: Hashable, Sendable, CustomStringConvertible,
                                                   CustomDebugStringConvertible {
    public let trackType: TrackType

    /// The code of RFC 5646 of the language, normalized.
    public var language: String? {
        get { box.storage.value(\FormatAttributes.Common.language) }
        set { mutate { $0.setValue(Util.normalizeLanguageCode(newValue), \FormatAttributes.Common.language) } }
    }

    /// The peak bitrate, or else the average one.
    public var bitrate: Int? { self.peakBitrate ?? self.averageBitrate }

    /// The MIME type of the samples: that of the codec of the format's media.
    public var sampleMimeType: MimeTypes? {
        switch trackType {
        case .video: box.storage.value(\FormatAttributes.Video.codec)?.mimeType
        case .audio: box.storage.value(\FormatAttributes.Audio.codec)?.mimeType
        case .text: box.storage.value(\FormatAttributes.Text.codec)?.mimeType
        case .metadata: box.storage.value(\FormatAttributes.Metadata.codec)
        default: nil
        }
    }

    /// One line with what tells formats apart: the id, the codec, the bitrate, and the size or the channels.
    public var description: String {
        var parts = ["\(trackType)"]
        if let id = self.id { parts.append("id=\(id)") }
        if let mimeType = sampleMimeType { parts.append(mimeType.rawValue) }
        if let codecs = self.codecs { parts.append("codecs=\(codecs)") }
        if let bitrate { parts.append("\(bitrate / 1000) kbit/s") }
        if let size = box.storage.value(\FormatAttributes.Video.size) { parts.append("\(size.width)x\(size.height)") }
        if let frameRate = box.storage.value(\FormatAttributes.Video.frameRate) { parts.append("\(frameRate) fps") }
        if let sampleRate = box.storage.value(\FormatAttributes.Audio.sampleRate) { parts.append("\(sampleRate) Hz") }
        if let channels = box.storage.value(\FormatAttributes.Audio.channelCount) { parts.append("\(channels) ch") }
        if let language { parts.append(language) }
        if let label = self.label { parts.append("\"\(label)\"") }
        return "Format(\(parts.joined(separator: ", ")))"
    }

    /// Every attribute, one per line.
    public var debugDescription: String {
        let lines = box.storage.description.components(separatedBy: ", ").map { "  \($0)" }
        return "Format(\(trackType)\n\(lines.joined(separator: "\n"))\n)"
    }

    var box: FormatBox

    public subscript<V>(dynamicMember keyPath: KeyPath<FormatAttributes.Common, FormatAttribute<V>>) -> V? {
        get { box.storage.value(keyPath) }
        set { mutate { $0.setValue(newValue, keyPath) } }
    }

    public subscript<V>(dynamicMember keyPath: KeyPath<FormatAttributes.Common, DefaultedFormatAttribute<V>>) -> V {
        get { box.storage.value(keyPath) }
        set { mutate { $0.setValue(newValue, keyPath) } }
    }

    public subscript<V>(dynamicMember keyPath: KeyPath<Scope, FormatAttribute<V>>) -> V? {
        get { box.storage.value(keyPath) }
        set { mutate { $0.setValue(newValue, keyPath) } }
    }

    public subscript<V>(dynamicMember keyPath: KeyPath<Scope, DefaultedFormatAttribute<V>>) -> V {
        get { box.storage.value(keyPath) }
        set { mutate { $0.setValue(newValue, keyPath) } }
    }

    /// Takes the attributes of `other`, which win over the ones already set. Codecs of the same type combine their
    /// attributes.
    public mutating func merge(_ other: Format<Scope>) {
        mutate { $0.merge(other.box.storage) }
    }

    /// The format with the attributes of `other`, which win over its own.
    public func merging(_ other: Format<Scope>) -> Format<Scope> {
        var format = self
        format.merge(other)
        return format
    }

    /// The format after `body` changes it.
    public func with(_ body: (inout Self) throws -> Void) rethrows -> Self {
        var format = self
        try body(&format)
        return format
    }

    public static func == (lhs: Format, rhs: Format) -> Bool {
        lhs.trackType == rhs.trackType && (lhs.box === rhs.box || lhs.box.storage == rhs.box.storage)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(trackType)
        hasher.combine(box.storage)
    }

    private mutating func mutate(_ body: (inout AttributeStorage) -> Void) {
        if !isKnownUniquelyReferenced(&box) {
            box = FormatBox(box.storage)
        }
        body(&box.storage)
    }
}

public typealias VideoFormat = Format<FormatAttributes.Video>
public typealias AudioFormat = Format<FormatAttributes.Audio>
public typealias TextFormat = Format<FormatAttributes.Text>
public typealias MetadataFormat = Format<FormatAttributes.Metadata>
public typealias AnyFormat = Format<FormatAttributes.AnyMedia>

/// The scope of one kind of media.
public protocol MediaAttributeScope: FormatAttributeScope {
    static var trackType: TrackType { get }
}

public extension Format where Scope: MediaAttributeScope {
    init() {
        self.init(trackType: Scope.trackType, box: FormatBox(AttributeStorage()))
    }

    init(_ configure: (inout Self) throws -> Void) rethrows {
        self.init()
        try configure(&self)
    }

    /// The format, if it describes this kind of media. Shares its storage.
    init?(_ format: AnyFormat) {
        guard format.trackType == Scope.trackType else { return nil }
        self.init(trackType: format.trackType, box: format.box)
    }
}

public extension Format where Scope == FormatAttributes.AnyMedia {
    /// The format as a video format, or `nil` for other media. Setting a format replaces this one.
    var video: VideoFormat? {
        get { VideoFormat(self) }
        set { if let newValue { self = AnyFormat(newValue) } }
    }

    /// The format as an audio format, or `nil` for other media. Setting a format replaces this one.
    var audio: AudioFormat? {
        get { AudioFormat(self) }
        set { if let newValue { self = AnyFormat(newValue) } }
    }

    /// The format as a text format, or `nil` for other media. Setting a format replaces this one.
    var text: TextFormat? {
        get { TextFormat(self) }
        set { if let newValue { self = AnyFormat(newValue) } }
    }

    /// The format as a format of timed metadata, or `nil` for other media. Setting a format replaces this one.
    var timedMetadata: MetadataFormat? {
        get { MetadataFormat(self) }
        set { if let newValue { self = AnyFormat(newValue) } }
    }

    init(_ format: Format<some MediaAttributeScope>) {
        self.init(trackType: format.trackType, box: format.box)
    }
}

/// The storage of a format, shared by its copies until one of them changes.
final class FormatBox: @unchecked Sendable {
    var storage: AttributeStorage

    init(_ storage: AttributeStorage) {
        self.storage = storage
    }
}

// MARK: - Codec attributes

/// The attributes of one codec: what its bitstream needs to be decoded, and what is known about it.
@dynamicMemberLookup
public struct CodecAttributes<Scope: FormatAttributeScope>: Hashable, Sendable, CustomStringConvertible {
    public var isEmpty: Bool { storage.isEmpty }
    public var description: String { "\(Scope.self)(\(storage.description))" }

    var storage: AttributeStorage

    init(storage: AttributeStorage) {
        self.storage = storage
    }

    public init() {
        storage = AttributeStorage()
    }

    public init(_ configure: (inout Self) throws -> Void) rethrows {
        self.init()
        try configure(&self)
    }

    public subscript<V>(dynamicMember keyPath: KeyPath<Scope, FormatAttribute<V>>) -> V? {
        get { storage.value(keyPath) }
        set { storage.setValue(newValue, keyPath) }
    }

    public subscript<V>(dynamicMember keyPath: KeyPath<Scope, DefaultedFormatAttribute<V>>) -> V {
        get { storage.value(keyPath) }
        set { storage.setValue(newValue, keyPath) }
    }
}

/// What the codec types share: a MIME type, and the attributes of the scopes of that kind of media.
protocol CodecStorage: AttributeMergeable {
    var mimeType: MimeTypes { get }
    var storage: AttributeStorage { get set }
}

extension CodecStorage {
    var codecDescription: String {
        storage.isEmpty ? mimeType.rawValue : "\(mimeType.rawValue)(\(storage.description))"
    }

    func merging(_ other: Self) -> Self {
        guard mimeType == other.mimeType else { return other }
        var merged = self
        merged.storage.merge(other.storage)
        return merged
    }

    func attributes<S: FormatAttributeScope>(_ scope: S.Type) -> CodecAttributes<S> {
        CodecAttributes(storage: storage.filtered(to: scope))
    }

    mutating func setAttributes<S: FormatAttributeScope>(_ attributes: CodecAttributes<S>) {
        storage.replace(S.self, with: attributes.storage)
    }
}
