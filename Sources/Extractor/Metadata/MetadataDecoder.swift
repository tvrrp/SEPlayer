//
//  MetadataDecoder.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.metadata.MetadataDecoder
//    androidx.media3.exoplayer.metadata.MetadataDecoderFactory
//  Copyright (C) 2016, 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
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
