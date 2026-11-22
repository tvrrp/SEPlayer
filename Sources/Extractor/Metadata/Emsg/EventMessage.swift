//
//  EventMessage.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.metadata.emsg.EventMessage
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// An event message: an `emsg` box of ISO/IEC 23009-1, or a DASH event.
public struct EventMessage: Metadata.Entry {
    /// The scheme of the message, which says how to read its data.
    public let schemeIdUri: String
    public let value: String
    /// The duration of the event, or `.invalid` if it isn't known.
    public let duration: CMTime
    public let id: Int64
    public let messageData: Data

    public var description: String {
        "EMSG: scheme=\(schemeIdUri), id=\(id), duration=\(duration.seconds), value=\(value)"
    }

    public var wrappedMetadataFormat: MetadataFormat? {
        switch schemeIdUri {
        case Self.id3SchemeIdAomedia,
             Self.id3SchemeIdApple:
            MetadataFormat { $0.codec = .applicationID3 }
        case Self.scte35SchemeId:
            MetadataFormat { $0.codec = .applicationSCTE35 }
        default:
            nil
        }
    }

    public var wrappedMetadataData: Data? {
        wrappedMetadataFormat != nil ? messageData : nil
    }

    public init(schemeIdUri: String, value: String, duration: CMTime, id: Int64, messageData: Data) {
        self.schemeIdUri = schemeIdUri
        self.value = value
        self.duration = duration
        self.id = id
        self.messageData = messageData
    }
}

public extension EventMessage {
    /// The scheme of ID3 tags in event messages, as AOMedia defines it.
    static let id3SchemeIdAomedia = "https://aomedia.org/emsg/ID3"
    /// The scheme of ID3 tags in event messages, as Apple's HLS documents define it.
    static let id3SchemeIdApple = "https://developer.apple.com/streaming/emsg-id3"
    /// The scheme of SCTE-35 splice information in event messages.
    static let scte35SchemeId = "urn:scte:scte35:2014:bin"
}

/// Decodes event messages written as their `emsg` version 0 payload: scheme, value, duration, id and data.
public struct EventMessageDecoder: MetadataDecoder {
    public init() {}

    public func decode(_ data: BlockBufferReader) -> Metadata? {
        var data = data
        guard let message = try? decode(&data) else { return nil }
        return Metadata(message)
    }

    func decode(_ data: inout BlockBufferReader) throws -> EventMessage {
        guard let schemeIdUri = data.readNullTerminatedString(), let value = data.readNullTerminatedString() else {
            throw ParserError.createForMalformedContainer(message: "Event message without a scheme or a value")
        }
        let milliseconds = try data.readInt(as: Int64.self)
        let id = try data.readInt(as: Int64.self)
        return try EventMessage(
            schemeIdUri: schemeIdUri,
            value: value,
            duration: milliseconds == Self.durationUnset ? .invalid : CMTime(value: milliseconds, timescale: 1000),
            id: id,
            messageData: data.readRemainingData()
        )
    }
}

private extension EventMessageDecoder {
    static let durationUnset = Int64(bitPattern: 0x8000_0000_0000_0001)
}
