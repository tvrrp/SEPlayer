//
//  Id3Decoder.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.metadata.id3.Id3Decoder
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Decodes ID3 tags (ID3v2.2, v2.3 and v2.4).
public struct Id3Decoder: MetadataDecoder {
    /// Decides whether to decode a frame, from the tag's major version and the id of the frame: three characters in
    /// ID3v2.2, four in the later versions.
    public typealias FramePredicate = @Sendable (_ majorVersion: Int, _ frameId: String) -> Bool

    /// The size of an ID3 tag header.
    public static let headerLength = 10
    /// `ID3`, the first three bytes of a tag.
    public static let tagIdentifier: [UInt8] = [0x49, 0x44, 0x33]

    /// A predicate that leaves out every frame.
    public static let noFramesPredicate: FramePredicate = { _, _ in false }
    /// A predicate that leaves out pictures.
    public static let noArtworkPredicate: FramePredicate = { _, frameId in frameId != "PIC" && frameId != "APIC" }

    private let framePredicate: FramePredicate?

    public init(framePredicate: FramePredicate? = nil) {
        self.framePredicate = framePredicate
    }

    public func decode(_ data: BlockBufferReader) -> Metadata? {
        var data = data
        guard let header = Self.readHeader(&data) else { return nil }

        let framesSize = min(header.framesSize, data.readableBytes)
        guard var frames = try? data.readSlice(length: max(framesSize, 0)) else {
            return nil
        }
        if header.isUnsynchronized {
            guard let synchronized = try? Self.removingUnsynchronization(from: frames) else {
                return nil
            }
            frames = synchronized
        }

        var tag = Tag(majorVersion: header.majorVersion, framePredicate: framePredicate)
        if !tag.hasValidFrames(frames) {
            // Some ID3v2.4 tags are written with plain frame sizes instead of synchsafe ones.
            tag.usesPlainFrameSizes = true
            guard header.majorVersion == 4, tag.hasValidFrames(frames) else {
                SELogger.warning(.metadata, "Failed to validate ID3 tag with majorVersion=\(header.majorVersion)")
                return nil
            }
        }
        return Metadata(entries: tag.decodeFrames(&frames))
    }

    /// The size of the frames of the tag whose header starts with `header`, without the header itself.
    static func framesSize(header: BlockBufferReader) -> Int? {
        guard header.readableBytes >= headerLength, header.readableBytesView.starts(with: tagIdentifier),
              let size = try? header.getInt(at: header.readerIndex + 6, as: UInt32.self) else {
            return nil
        }
        return BlockBufferReader.synchSafeInt(size)
    }
}

// MARK: - Tag header

private extension Id3Decoder {
    struct Header {
        let majorVersion: Int
        let isUnsynchronized: Bool
        let framesSize: Int
    }

    static func readHeader(_ data: inout BlockBufferReader) -> Header? {
        guard data.readableBytes >= headerLength else {
            SELogger.warning(.metadata, "Data too short to be an ID3 tag")
            return nil
        }

        do {
            let identifier = try data.readBytes(length: tagIdentifier.count)
            guard identifier == tagIdentifier else {
                SELogger.warning(.metadata, "Unexpected first three bytes of ID3 tag header: \(identifier)")
                return nil
            }

            let majorVersion = try Int(data.readInt(as: UInt8.self))
            try data.skip(1) // Minor version.
            let flags = try data.readInt(as: UInt8.self)
            var framesSize = try data.readSynchSafeInt()
            let hasExtendedHeader = flags & 0x40 != 0

            switch majorVersion {
            case 2:
                // The same bit says the tag is compressed, by a scheme that was never defined.
                guard !hasExtendedHeader else {
                    SELogger.warning(.metadata, "Skipped ID3 tag with majorVersion=2 and undefined compression scheme")
                    return nil
                }
            case 3:
                if hasExtendedHeader {
                    // The extended header size excludes the size field.
                    let extendedHeaderSize = try Int(data.readInt(as: Int32.self))
                    try data.skip(extendedHeaderSize)
                    framesSize -= extendedHeaderSize + 4
                }
            case 4:
                if hasExtendedHeader {
                    // The extended header size includes the size field.
                    let extendedHeaderSize = try data.readSynchSafeInt()
                    try data.skip(extendedHeaderSize - 4)
                    framesSize -= extendedHeaderSize
                }
                let hasFooter = flags & 0x10 != 0
                if hasFooter {
                    framesSize -= headerLength
                }
            default:
                SELogger.warning(.metadata, "Skipped ID3 tag with unsupported majorVersion=\(majorVersion)")
                return nil
            }

            // The unsynchronization flag is advisory only in version 4: frame flags are used instead.
            let isUnsynchronized = majorVersion < 4 && flags & 0x80 != 0
            return Header(majorVersion: majorVersion, isUnsynchronized: isUnsynchronized, framesSize: framesSize)
        } catch {
            return nil
        }
    }

    /// The bytes of `data` without the zero byte that follows each 0xFF byte.
    static func removingUnsynchronization(from data: BlockBufferReader) throws -> BlockBufferReader {
        var previous: UInt8 = 0
        let bytes = data.readableBytesView.filter { byte in
            defer { previous = byte }
            return previous != 0xFF || byte != 0x00
        }
        return try BlockBufferReader(bytes: bytes)
    }
}

// MARK: - Frames

private extension Id3Decoder {
    /// What reading the frames of a tag depends on.
    struct Tag {
        let majorVersion: Int
        let framePredicate: FramePredicate?
        /// Whether the frame sizes of an ID3v2.4 tag are plain integers, rather than the synchsafe ones the
        /// specification asks for.
        var usesPlainFrameSizes = false

        var frameHeaderLength: Int { majorVersion == 2 ? 6 : 10 }
    }

    struct FrameHeader {
        let id: String
        let size: Int
        let flags: FrameFlags
        /// Whether the header is zero padding, which ends the frames of a tag.
        let isPadding: Bool
    }

    struct FrameFlags {
        var isCompressed = false
        var isEncrypted = false
        var isUnsynchronized = false
        var hasDataLength = false
        var hasGroupIdentifier = false

        /// The size of what comes before the body of a frame with these flags.
        var prefixLength: Int { (hasGroupIdentifier ? 1 : 0) + (hasDataLength ? 4 : 0) }

        init(majorVersion: Int, flags: UInt16) {
            if majorVersion == 3 {
                isCompressed = flags & 0x0080 != 0
                isEncrypted = flags & 0x0040 != 0
                hasGroupIdentifier = flags & 0x0020 != 0
                // A version 3 frame has a data length only when it is compressed.
                hasDataLength = isCompressed
            } else if majorVersion == 4 {
                hasGroupIdentifier = flags & 0x0040 != 0
                isCompressed = flags & 0x0008 != 0
                isEncrypted = flags & 0x0004 != 0
                isUnsynchronized = flags & 0x0002 != 0
                hasDataLength = flags & 0x0001 != 0
            }
        }
    }
}

private extension Id3Decoder.Tag {
    typealias FrameHeader = Id3Decoder.FrameHeader
    typealias FrameFlags = Id3Decoder.FrameFlags

    /// Whether the frames fill `frames` exactly, up to its end or to zero padding.
    func hasValidFrames(_ frames: BlockBufferReader) -> Bool {
        var frames = frames
        while frames.readableBytes >= frameHeaderLength {
            guard let header = try? readFrameHeader(&frames) else {
                return false
            }
            if header.isPadding { return true }
            guard header.size >= header.flags.prefixLength, (try? frames.skip(header.size)) != nil else {
                return false
            }
        }
        return true
    }

    func decodeFrames(_ frames: inout BlockBufferReader) -> [any Id3Frame] {
        var decoded = [any Id3Frame]()
        while frames.readableBytes >= frameHeaderLength {
            if let frame = decodeFrame(&frames) {
                decoded.append(frame)
            }
        }
        return decoded
    }

    /// Reads the next frame of `frames`, moving past it, or to the end if no frame follows.
    func decodeFrame(_ frames: inout BlockBufferReader) -> (any Id3Frame)? {
        guard let header = try? readFrameHeader(&frames), !header.isPadding else {
            frames.moveReaderIndex(forwardBy: frames.readableBytes)
            return nil
        }
        guard var body = try? frames.readSlice(length: min(header.size, frames.readableBytes)),
              body.readableBytes == header.size else {
            SELogger.warning(.metadata, "Frame size exceeds remaining tag data")
            frames.moveReaderIndex(forwardBy: frames.readableBytes)
            return nil
        }

        if let framePredicate, !framePredicate(majorVersion, header.id) {
            return nil
        }
        guard !header.flags.isCompressed, !header.flags.isEncrypted else {
            SELogger.warning(.metadata, "Skipping unsupported compressed or encrypted frame")
            return nil
        }

        do {
            try body.skip(header.flags.prefixLength)
            if header.flags.isUnsynchronized {
                body = try Id3Decoder.removingUnsynchronization(from: body)
            }
            let frame = try decodeFrameBody(id: header.id, &body)
            if frame == nil {
                SELogger.warning(.metadata, "Failed to decode frame: id=\(header.id), size=\(header.size)")
            }
            return frame
        } catch {
            SELogger.warning(.metadata, "Failed to decode frame: id=\(header.id), size=\(header.size): \(error)")
            return nil
        }
    }

    func readFrameHeader(_ frames: inout BlockBufferReader) throws -> FrameHeader {
        let idBytes = try frames.readBytes(length: majorVersion == 2 ? 3 : 4)
        let size: Int
        var rawFlags: UInt16 = 0
        switch majorVersion {
        case 2:
            size = try frames.readUInt24()
        case 3:
            size = try Int(frames.readInt(as: UInt32.self))
            rawFlags = try frames.readInt()
        default:
            let rawSize = try frames.readInt(as: UInt32.self)
            // No byte of a synchsafe size has its top bit set.
            guard usesPlainFrameSizes || rawSize & 0x8080_8080 == 0 else {
                throw ParserError.createForMalformedContainer(message: "Frame size isn't a synchsafe integer")
            }
            size = usesPlainFrameSizes ? Int(rawSize) : BlockBufferReader.synchSafeInt(rawSize)
            rawFlags = try frames.readInt()
        }
        return FrameHeader(
            id: String(bytes: idBytes, encoding: .isoLatin1) ?? "",
            size: size,
            flags: FrameFlags(majorVersion: majorVersion, flags: rawFlags),
            isPadding: idBytes.allSatisfy { $0 == 0 } && size == 0 && rawFlags == 0
        )
    }

    /// Decodes the body of a frame. Frame ids of ID3v2.2 are those of the later versions without their last character.
    func decodeFrameBody(id: String, _ body: inout BlockBufferReader) throws -> (any Id3Frame)? {
        let isLegacy = majorVersion == 2
        switch id {
        case isLegacy ? "TXX" : "TXXX":
            return try decodeTxxxFrame(&body)
        case isLegacy ? "WXX" : "WXXX":
            return try decodeWxxxFrame(&body)
        case isLegacy ? "GEO" : "GEOB":
            return try decodeGeobFrame(&body)
        case isLegacy ? "PIC" : "APIC":
            return try decodeApicFrame(&body)
        case isLegacy ? "COM" : "COMM":
            return try decodeCommentFrame(&body)
        case "PRIV":
            return try decodePrivFrame(&body)
        case "CHAP":
            return try decodeChapterFrame(&body)
        case "CTOC":
            return try decodeChapterTocFrame(&body)
        case "MLLT":
            return try decodeMlltFrame(&body)
        case _ where id.hasPrefix("T"):
            return try decodeTextInformationFrame(&body, id: id)
        case _ where id.hasPrefix("W"):
            return try UrlLinkFrame(id: id, description: nil, url: body.readTerminatedString(encoding: .isoLatin1))
        default:
            return try BinaryFrame(id: id, data: body.readRemainingData())
        }
    }

    func decodeTxxxFrame(_ body: inout BlockBufferReader) throws -> TextInformationFrame? {
        guard body.readableBytes >= 1 else { return nil }
        let encoding = try body.readTextEncoding()
        let description = try body.readTerminatedString(encoding: encoding)
        return try TextInformationFrame(id: "TXXX", description: description, values: body.readStrings(encoding: encoding))
    }

    func decodeTextInformationFrame(_ body: inout BlockBufferReader, id: String) throws -> TextInformationFrame? {
        guard body.readableBytes >= 1 else { return nil }
        let encoding = try body.readTextEncoding()
        return try TextInformationFrame(id: id, description: nil, values: body.readStrings(encoding: encoding))
    }

    func decodeWxxxFrame(_ body: inout BlockBufferReader) throws -> UrlLinkFrame? {
        guard body.readableBytes >= 1 else { return nil }
        let encoding = try body.readTextEncoding()
        let description = try body.readTerminatedString(encoding: encoding)
        let url = try body.readTerminatedString(encoding: .isoLatin1)
        return UrlLinkFrame(id: "WXXX", description: description, url: url)
    }

    func decodePrivFrame(_ body: inout BlockBufferReader) throws -> PrivFrame {
        let owner = try body.readTerminatedString(encoding: .isoLatin1)
        return try PrivFrame(owner: owner, privateData: body.readRemainingData())
    }

    func decodeGeobFrame(_ body: inout BlockBufferReader) throws -> GeobFrame {
        let encoding = try body.readTextEncoding()
        let mimeType = try body.readTerminatedString(encoding: .isoLatin1).lowercased()
        let filename = try body.readTerminatedString(encoding: encoding)
        let description = try body.readTerminatedString(encoding: encoding)
        return try GeobFrame(
            mimeType: mimeType,
            filename: filename,
            description: description,
            data: body.readRemainingData()
        )
    }

    func decodeApicFrame(_ body: inout BlockBufferReader) throws -> ApicFrame {
        let encoding = try body.readTextEncoding()
        var mimeType: String
        if majorVersion == 2 {
            // A three letter image format.
            mimeType = try "image/" + body.readString(length: 3, lossyEncoding: .isoLatin1).lowercased()
            if mimeType == "image/jpg" {
                mimeType = "image/jpeg"
            }
        } else {
            mimeType = try body.readTerminatedString(encoding: .isoLatin1).lowercased()
            if !mimeType.contains("/") {
                mimeType = "image/" + mimeType
            }
        }

        let pictureType = try Int(body.readInt(as: UInt8.self))
        let description = try body.readTerminatedString(encoding: encoding)
        return try ApicFrame(
            mimeType: mimeType,
            description: description,
            pictureType: pictureType,
            pictureData: body.readRemainingData()
        )
    }

    func decodeCommentFrame(_ body: inout BlockBufferReader) throws -> CommentFrame? {
        guard body.readableBytes >= 4 else { return nil }
        let encoding = try body.readTextEncoding()
        let language = try body.readString(length: 3, lossyEncoding: .isoLatin1)
        let description = try body.readTerminatedString(encoding: encoding)
        return try CommentFrame(language: language, description: description, text: body.readTerminatedString(encoding: encoding))
    }

    func decodeChapterFrame(_ body: inout BlockBufferReader) throws -> ChapterFrame? {
        let chapterId = try body.readTerminatedString(encoding: .isoLatin1)
        // Both in milliseconds.
        let startTime = try CMTime(value: CMTimeValue(body.readInt(as: Int32.self)), timescale: 1000)
        let endTime = try CMTime(value: CMTimeValue(body.readInt(as: Int32.self)), timescale: 1000)
        guard startTime <= endTime else { return nil }
        let startOffset = try body.readInt(as: UInt32.self)
        let endOffset = try body.readInt(as: UInt32.self)
        return ChapterFrame(
            chapterId: chapterId,
            startTime: startTime,
            endTime: endTime,
            // All bits set: the offset isn't given.
            startOffset: startOffset == .max ? nil : Int(startOffset),
            endOffset: endOffset == .max ? nil : Int(endOffset),
            subFrames: decodeSubFrames(&body)
        )
    }

    func decodeChapterTocFrame(_ body: inout BlockBufferReader) throws -> ChapterTocFrame {
        let elementId = try body.readTerminatedString(encoding: .isoLatin1)
        let flags = try body.readInt(as: UInt8.self)
        let childCount = try Int(body.readInt(as: UInt8.self))
        let children = try (0 ..< childCount).map { _ in try body.readTerminatedString(encoding: .isoLatin1) }
        return ChapterTocFrame(
            elementId: elementId,
            isRoot: flags & 0x02 != 0,
            isOrdered: flags & 0x01 != 0,
            children: children,
            subFrames: decodeSubFrames(&body)
        )
    }

    /// The frames embedded in the rest of a chapter frame.
    func decodeSubFrames(_ body: inout BlockBufferReader) -> [any Id3Frame] {
        var frames = [any Id3Frame]()
        while body.readableBytes > 0 {
            if let frame = decodeFrame(&body) {
                frames.append(frame)
            }
        }
        return frames
    }

    /// Reads an `MLLT` frame, ID3v2.4 native frames section 4.6.
    func decodeMlltFrame(_ body: inout BlockBufferReader) throws -> MlltFrame {
        let mpegFramesBetweenReference = try Int(body.readInt(as: UInt16.self))
        let bytesBetweenReference = try body.readUInt24()
        let millisecondsBetweenReference = try body.readUInt24()
        let bitsForBytesDeviation = try Int(body.readInt(as: UInt8.self))
        let bitsForMillisecondsDeviation = try Int(body.readInt(as: UInt8.self))

        let bitsPerReference = bitsForBytesDeviation + bitsForMillisecondsDeviation
        let referenceCount = bitsPerReference > 0 ? 8 * body.readableBytes / bitsPerReference : 0
        var references = try BlockBufferBitReader(reader: body.readSlice(length: body.readableBytes))
        var bytesDeviations = [Int]()
        var millisecondsDeviations = [Int]()
        for _ in 0 ..< referenceCount {
            try bytesDeviations.append(references.readBits(bitsForBytesDeviation))
            try millisecondsDeviations.append(references.readBits(bitsForMillisecondsDeviation))
        }

        return MlltFrame(
            mpegFramesBetweenReference: mpegFramesBetweenReference,
            bytesBetweenReference: bytesBetweenReference,
            millisecondsBetweenReference: millisecondsBetweenReference,
            bytesDeviations: bytesDeviations,
            millisecondsDeviations: millisecondsDeviations
        )
    }
}

// MARK: - Text

private extension BlockBufferReader {
    /// Reads the byte that says how the text of a frame is encoded. A value that isn't defined reads as ISO-8859-1.
    mutating func readTextEncoding() throws -> String.Encoding {
        switch try readInt(as: UInt8.self) {
        case 1: .utf16
        case 2: .utf16BigEndian
        case 3: .utf8
        default: .isoLatin1
        }
    }

    /// Reads the strings that are left, up to the first empty one. There is always at least one.
    mutating func readStrings(encoding: String.Encoding) throws -> [String] {
        var strings = [String]()
        while readableBytes > 0 {
            let string = try readTerminatedString(encoding: encoding)
            if string.isEmpty { break }
            strings.append(string)
        }
        return strings.isEmpty ? [""] : strings
    }
}
