//
//  SampleEntryValues.swift
//  SEPlayer
//

import Foundation

/// A sample entry as the container stores it, whole from its size field.
public struct SampleEntry: Hashable, Sendable {
    public var bytes: Data
    /// Whether it is a QuickTime sample description rather than an ISO sample entry.
    public var isQuickTime: Bool

    public init(bytes: Data, isQuickTime: Bool) {
        self.bytes = bytes
        self.isQuickTime = isQuickTime
    }
}

/// A box of a sample entry, as ISO base media files write it: the configuration of a codec, such as `avcC` or
/// `esds`, or another description of the samples, such as `btrt`.
public struct MediaBox: Hashable, Sendable {
    public var type: FourCharacterCode
    /// The box after its size and type.
    public var payload: Data

    public init(type: FourCharacterCode, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

public extension Sequence<MediaBox> {
    /// The payload of the first box of `type`.
    func payload(of type: FourCharacterCode) -> Data? {
        first { $0.type == type }?.payload
    }
}

/// The Common Encryption of ISO/IEC 23001-7 that protects the media.
public struct CommonEncryption: Hashable, Sendable {
    /// The format of the media before protection.
    public var originalFormat: FourCharacterCode?
    /// The payload of the `tenc` box, from its version: the default key identifier and how samples are protected.
    public var trackEncryptionBox: Data?

    public init(originalFormat: FourCharacterCode? = nil, trackEncryptionBox: Data? = nil) {
        self.originalFormat = originalFormat
        self.trackEncryptionBox = trackEncryptionBox
    }
}
