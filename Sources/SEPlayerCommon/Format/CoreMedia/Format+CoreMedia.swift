//
//  Format+CoreMedia.swift
//  SEPlayer
//

import CoreMedia
import Foundation

/// A format that can't be turned into a format description.
public enum FormatConversionError: Error {
    case missingAttribute(String)
    case unsupportedCodec(MimeTypes?)
    case mediaTypeMismatch
}

public extension Format where Scope == FormatAttributes.AnyMedia {
    /// A format description of the samples, made for the format's kind of media.
    func formatDescription() throws -> CMFormatDescription {
        if let video = VideoFormat(self) {
            return try video.formatDescription()
        } else if let audio = AudioFormat(self) {
            return try audio.formatDescription()
        } else if let text = TextFormat(self) {
            return try text.formatDescription()
        } else if let metadata = MetadataFormat(self) {
            return try metadata.formatDescription()
        }
        throw FormatConversionError.unsupportedCodec(sampleMimeType)
    }
}

extension Format {
    /// The extensions of what every format has: the sample entry, its boxes and its protection.
    ///
    /// - Parameter isDescribed: Whether the rest of the description tells what a box does, so that it isn't kept as
    ///   it is too.
    func commonExtensions(isDescribed: (MediaBox) -> Bool) -> [CFString: Any] {
        var extensions: [CFString: Any] = [:]
        if let entry = self.sampleEntry {
            let key = entry.isQuickTime
                ? kCMFormatDescriptionExtension_VerbatimSampleDescription
                : kCMFormatDescriptionExtension_VerbatimISOSampleEntry
            extensions[key] = entry.bytes
        }
        // Boxes of a type that comes more than once are an array, in their order.
        var payloads: [String: [Data]] = [:]
        for box in self.boxes where !isDescribed(box) {
            payloads[box.type.description, default: []].append(box.payload)
        }
        if !payloads.isEmpty {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                payloads.mapValues { $0.count == 1 ? $0[0] as Any : $0 as Any }
        }
        if let encryption = self.encryption {
            extensions[CommonKey.protected] = true
            extensions[CommonKey.originalFormat] = encryption.originalFormat.map { Int32(bitPattern: $0.rawValue) }
            extensions[CommonKey.trackEncryptionBox] = encryption.trackEncryptionBox
        }
        return extensions
    }

    /// Takes what every format has from the extensions of a format description.
    mutating func readCommonExtensions(_ extensions: [CFString: Any]) {
        if let bytes = extensions[kCMFormatDescriptionExtension_VerbatimISOSampleEntry] as? Data {
            self.sampleEntry = SampleEntry(bytes: bytes, isQuickTime: false)
        } else if let bytes = extensions[kCMFormatDescriptionExtension_VerbatimSampleDescription] as? Data {
            self.sampleEntry = SampleEntry(bytes: bytes, isQuickTime: true)
        }
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any] ?? [:]
        self.boxes = atoms.sorted { $0.key < $1.key }.flatMap { type, value in
            let payloads = value as? [Data] ?? (value as? Data).map { [$0] } ?? []
            return payloads.map { MediaBox(type: FourCharacterCode(type), payload: $0) }
        }
        if extensions[CommonKey.protected] as? Bool == true {
            let originalFormat = (extensions[CommonKey.originalFormat] as? NSNumber)
                .map { FourCharacterCode(UInt32(truncatingIfNeeded: $0.int64Value)) }
            self.encryption = CommonEncryption(
                originalFormat: originalFormat,
                trackEncryptionBox: extensions[CommonKey.trackEncryptionBox] as? Data
            )
        }
    }
}

/// The names of the extensions of protected media, which systems before iOS 17 have no constants for.
private enum CommonKey {
    static var protected: CFString { "CommonEncryptionProtected" as CFString }
    static var originalFormat: CFString { "CommonEncryptionOriginalFormat" as CFString }
    static var trackEncryptionBox: CFString { "CommonEncryptionTrackEncryptionBox" as CFString }
}

public extension Format where Scope == FormatAttributes.Text {
    /// `sepc`: the subtype of samples of cues a subtitle parser read.
    static var cuesMediaSubType: CMFormatDescription.MediaSubType { .init(rawValue: 0x7365_7063) }

    /// A format description of samples of cues; other text is read into cues before it is played.
    func formatDescription() throws -> CMFormatDescription {
        guard self.codec?.mimeType == .applicationSEPlayerCues else {
            throw FormatConversionError.unsupportedCodec(self.codec?.mimeType)
        }
        return try CMFormatDescription(mediaType: .text, mediaSubType: Self.cuesMediaSubType)
    }
}

public extension Format where Scope == FormatAttributes.Metadata {
    /// `sepm`: the subtype of metadata other than ID3, such as ICY or event messages.
    static var mediaSubType: CMFormatDescription.MediaSubType { .init(rawValue: 0x7365_706D) }

    /// A format description of timed metadata, whose samples are read whole by their decoder.
    func formatDescription() throws -> CMFormatDescription {
        let isID3 = self.codec == .applicationID3
        let subType = isID3 ? CMFormatDescription.MediaSubType(rawValue: kCMMetadataFormatType_ID3) : Self.mediaSubType
        return try CMFormatDescription(mediaType: .metadata, mediaSubType: subType)
    }
}
