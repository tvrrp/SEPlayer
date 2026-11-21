//
//  MetadataDecoder.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import SEPlayerCommon

/// Decodes the samples of a metadata track.
public protocol MetadataDecoder: Sendable {
    /// Decodes one sample.
    ///
    /// - Returns: The metadata of the sample, or `nil` if it has none that can be read.
    func decode(_ data: BlockBufferReader) -> Metadata?
}

/// Makes the decoders of metadata tracks.
public protocol MetadataDecoderFactory: Sendable {
    func supportsFormat(_ format: MetadataFormat) -> Bool
    /// The decoder of `format`, or `nil` if the factory doesn't support it.
    func createDecoder(for format: MetadataFormat) -> (any MetadataDecoder)?
}

/// Makes decoders for ID3, ICY and `emsg` (event message) metadata.
public struct DefaultMetadataDecoderFactory: MetadataDecoderFactory {
    public init() {}

    public func supportsFormat(_ format: MetadataFormat) -> Bool {
        createDecoder(for: format) != nil
    }

    public func createDecoder(for format: MetadataFormat) -> (any MetadataDecoder)? {
        switch format.codec {
        case .applicationID3: Id3Decoder()
        case .applicationEMSG: EventMessageDecoder()
        case .applicationICY: IcyDecoder()
        default: nil
        }
    }
}
