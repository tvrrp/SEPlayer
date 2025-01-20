//
//  BoxParser+ESDescriptor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import AudioToolbox
import CoreMedia
import Foundation

extension BoxParser {
    struct ESDescriptor {
        let codecInfo: CMAudioFormatDescription?

        enum ObjectTypeIndication: UInt8 {
            case kISO_14496_3 = 0x40 // MPEG4 AAC
            case kISO_13818_7_AAC_LC = 0x67 // MPEG2 AAC-LC
            case kEAC3 = 0xa6 // Dolby Digital Plus
        }

        init(parent: inout ByteBuffer, box payload: Data) throws {
            try readFullboxExtra(reader: &parent)
            var codecInfo: CMAudioFormatDescription?

            while parent.readableBytes > 0 {
                let (tag, size) = try ESDescriptor.readDescription(reader: &parent)
                if tag == 0x03 {
                    codecInfo = try ESDescriptor.readESDescription(
                        reader: &parent, size: Int(size), box: payload
                    )
                    break
                }
            }

            self.codecInfo = codecInfo
        }

        static func readDescription(reader: inout ByteBuffer) throws -> (tag: UInt8, size: UInt32) {
            let tag = try reader.readInt(as: UInt8.self)
            var size: UInt32 = 0
            for _ in 0..<4 {
                let extendedOrLen = try reader.readInt(as: UInt8.self)
                size = (size << 7) + UInt32(extendedOrLen & 0x7F)
                if (extendedOrLen & 0x80) == 0 {
                    break
                }
            }
            return (tag, size)
        }

        // В ES дескрипторе много разной инфы, которую тяжело парсить руками.
        // Плюс нужно читать стандарт, чтобы уметь парсить.
        // Но нам везет и AudioFormatGetProperty сможет спарсить за нас весь esds box
        // Но для этого нужно сначала получить ObjectTypeIndication, который лежит в DecoderConfigDescriptor
        static func readESDescription(reader: inout ByteBuffer, size: Int, box payload: Data) throws -> CMAudioFormatDescription? {
            let start = reader.readerIndex
            reader.moveReaderIndex(forwardBy: 3)

            var current = reader.readerIndex
            let end = start + size

            while current < end {
                let (tag, _) = try readDescription(reader: &reader)
                
                switch tag {
                case 0x04:
                    let type = try ObjectTypeIndication(rawValue: reader.readInt(as: UInt8.self))
                    let formatDescription = try createFormatDescription(type: type, payload: payload)
                    return formatDescription
                default:
                    reader.moveReaderIndex(forwardBy: size)
                }

                current = reader.readerIndex
            }

            return nil
        }

        static func createFormatDescription(type: ObjectTypeIndication?, payload: Data) throws -> CMAudioFormatDescription? {
            let format: AudioFormatID? = switch type {
            case .kISO_14496_3, .kISO_13818_7_AAC_LC:
                kAudioFormatMPEG4AAC
            case .kEAC3, .none:
                nil
            }

            guard let format else {
                throw BoxParser.BoxParserErrors.badBoxContent(
                    type: .esds, reason: "Unknown ES Descriptor Object Type Indication"
                )
            }

            var description = AudioStreamBasicDescription()
            description.mFormatID = format
            var size = Int32(MemoryLayout<AudioStreamBasicDescription>.size)
            let propertyID = kAudioFormatProperty_FormatInfo

            try payload.withUnsafeBytes { pointer in
                guard let baseAddress = pointer.baseAddress else { return kAudio_ParamError }
                return AudioFormatGetProperty(propertyID, UInt32(payload.count), baseAddress, &size, &description)
            }.validate()

            return try CMAudioFormatDescription(audioStreamBasicDescription: description)
        }
    }
}
