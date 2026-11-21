//
//  ElementaryStreamDescriptor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import SEPlayerCommon

/// An MPEG-4 elementary stream descriptor of ISO/IEC 14496-1, the payload of an `esds` box after its version and
/// flags: the stream's codec and its decoder config.
struct ElementaryStreamDescriptor {
    /// The objectTypeIndication of the DecoderConfigDescriptor, Table 5, such as 0x40 for MPEG-4 audio.
    let objectTypeIndication: Int
    /// The streamType of the DecoderConfigDescriptor, Table 6, 5 for audio.
    let streamType: Int
    let maxBitrate: Int
    let averageBitrate: Int
    /// The DecoderSpecificInfo, such as an AudioSpecificConfig.
    let decoderSpecificInfo: BlockBufferReader?

    private enum Tag: UInt8 {
        case elementaryStream = 0x03
        case decoderConfig = 0x04
        case decoderSpecificInfo = 0x05
    }

    /// - Parameter readsClockReference: Whether OCR_ES_Id follows its flag. Audio decoders read the flag alone, so
    ///   descriptors of their streams are read as they read them.
    init?(esds: BlockBufferReader, readsClockReference: Bool = true) {
        var reader = esds
        // ES_Descriptor: ES_ID (2), flags (1), and what the flags announce.
        do {
            _ = try reader.readDescriptorHeader(tag: Tag.elementaryStream.rawValue)
            try reader.skip(2) // ES_ID
            let flags = try reader.readInt(as: UInt8.self)
            if flags & 0x80 != 0 { try reader.skip(2) } // dependsOn_ES_ID
            if flags & 0x40 != 0 { try reader.skip(Int(reader.readInt(as: UInt8.self))) } // URL
            if flags & 0x20 != 0, readsClockReference { try reader.skip(2) } // OCR_ES_Id

            // DecoderConfigDescriptor: objectTypeIndication (1), streamType (6), upStream (1), reserved (1),
            // bufferSizeDB (3), maxBitrate (4), avgBitrate (4), then a DecoderSpecificInfo.
            guard try reader.readDescriptorHeader(tag: Tag.decoderConfig.rawValue) >= 13 else {
                return nil
            }
            objectTypeIndication = try Int(reader.readInt(as: UInt8.self))
            streamType = try Int(reader.readInt(as: UInt8.self) >> 2)
            try reader.skip(3) // bufferSizeDB
            maxBitrate = try Int(reader.readInt(as: UInt32.self))
            averageBitrate = try Int(reader.readInt(as: UInt32.self))
            decoderSpecificInfo = (try? reader.readDescriptorHeader(tag: Tag.decoderSpecificInfo.rawValue))
                .flatMap { try? reader.readSlice(length: $0) }
        } catch {
            return nil
        }
    }
}

extension BlockBufferReader {
    /// Reads the header of a descriptor of ISO/IEC 14496-1, 8.3.3: its tag and expandable size.
    ///
    /// - Returns: The size of the descriptor's payload.
    /// - Throws: For another tag, or a header that doesn't fit.
    mutating func readDescriptorHeader(tag: UInt8) throws -> Int {
        guard try readInt(as: UInt8.self) == tag else { throw EndOfFileError() }
        var size = 0
        for _ in 0 ..< 4 {
            let byte = try readInt(as: UInt8.self)
            size = size << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { break }
        }
        return size
    }

    /// Moves the reader index forward by `count` bytes.
    ///
    /// - Throws: When fewer bytes are readable.
    mutating func skip(_ count: Int) throws {
        guard count >= 0, readableBytes >= count else { throw EndOfFileError() }
        moveReaderIndex(forwardBy: count)
    }
}

extension ElementaryStreamDescriptor {
    /// The bytes of a descriptor of a stream that has nothing but a decoder config, as the payload of an `esds` box
    /// after its version and flags.
    ///
    /// - Parameters:
    ///   - objectTypeIndication: The codec, Table 5.
    ///   - streamType: The kind of the stream, Table 6.
    ///   - decoderSpecificInfo: The decoder config, such as an AudioSpecificConfig.
    static func bytes(
        objectTypeIndication: Int,
        streamType: Int,
        decoderSpecificInfo: some Collection<UInt8>
    ) -> [UInt8] {
        let decoderConfig: [UInt8] = [
            UInt8(objectTypeIndication),
            UInt8(streamType << 2 | 1), // streamType, upStream, reserved
            0x00, 0x00, 0x00, // bufferSizeDB
            0x00, 0x00, 0x00, 0x00, // maxBitrate
            0x00, 0x00, 0x00, 0x00, // avgBitrate
        ] + descriptor(.decoderSpecificInfo, decoderSpecificInfo)
        // ES_ID (2) and flags (1), then the config and an SLConfigDescriptor predefined for MP4.
        let payload = [0x00, 0x00, 0x00] + descriptor(.decoderConfig, decoderConfig) + [slConfigTag, 0x01, 0x02]
        return descriptor(.elementaryStream, payload)
    }

    /// A descriptor with its tag and its expandable size, 8.3.3.
    private static func descriptor(_ tag: Tag, _ payload: some Collection<UInt8>) -> [UInt8] {
        var size = [UInt8(payload.count & 0x7F)]
        var remainder = payload.count >> 7
        while remainder > 0 {
            size.insert(UInt8(0x80 | remainder & 0x7F), at: 0)
            remainder >>= 7
        }
        return [tag.rawValue] + size + payload
    }

    private static let slConfigTag: UInt8 = 0x06

    /// The audio object type of an AudioSpecificConfig of ISO/IEC 14496-3, 1.6.2.1, such as 2 for AAC LC.
    var audioObjectType: Int? {
        guard objectTypeIndication == 0x40, let info = decoderSpecificInfo, info.readableBytes > 0,
              let first = try? info.getInt(at: info.readerIndex, as: UInt8.self) else {
            return nil
        }
        let type = Int(first >> 3)
        guard type == 31 else { return type }
        guard let second = try? info.getInt(at: info.readerIndex + 1, as: UInt8.self) else {
            return nil
        }
        return 32 + Int((first & 0x07) << 3 | second >> 5)
    }
}
