//
//  BoxParser+Stsd.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import AudioToolbox
import Foundation
import CoreMedia
import CoreAudio

extension BoxParser {
    struct StsdData {
        let descriptions: [Track.TrackFormat]

        init(stsd: ByteBuffer, trackId: Int) throws {
            var stsd = stsd
            stsd.moveReaderIndex(to: Int(MP4Box.fullHeaderSize))
            let descriptionCount = try stsd.readInt(as: UInt32.self)
            var descriptions: [Track.TrackFormat] = []

            for _ in 0..<descriptionCount {
                let childStartPosition = stsd.readerIndex
                let childAtomSize = try stsd.readInt(as: UInt32.self)
                let childAtomType = try MP4Box.BoxType(rawValue: stsd.readInt(as: UInt32.self))

                if let childAtomType {
                    switch childAtomType {
                    case .avc1:
                        if let codecInfo = try? VideoSampleEntry(parent: &stsd, childAtomType: childAtomType).codecInfo {
                            descriptions.append(.video(codecInfo))
                        }
                    case .mp4a:
                        if let codecInfo = try? AudioSampleEntry(parent: &stsd).codecInfo {
                            descriptions.append(.audio(codecInfo))
                        }
                    default:
                        break
                    }
                }

                stsd.moveReaderIndex(to: childStartPosition + Int(childAtomSize))
            }

            guard !descriptions.isEmpty else {
                throw BoxParser.BoxParserErrors.badBoxContent(
                    type: .stsd, reason: "Sample Description Box missing valid description"
                )
            }

            self.descriptions = descriptions
        }
    }

    struct VideoSampleEntry {
        let codecInfo: CMVideoFormatDescription?

        init(parent: inout ByteBuffer, childAtomType: MP4Box.BoxType) throws {
            // Skip all metadata
            parent.moveReaderIndex(forwardBy: 78 + MP4Box.boxSize)
            let childAtomType = try MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))
            
            switch childAtomType {
            case .avcC:
                codecInfo = try AVCCodecInfo(parent: &parent).codecInfo
            default:
                codecInfo = nil
            }
        }
    }
    
    private struct AVCCodecInfo {
        let codecInfo: CMVideoFormatDescription

        init(parent: inout ByteBuffer) throws {
            // Skip avvC config version, profile compatibility, level indication
            // We don't need them to create CMVideoFormatDescription
            parent.moveReaderIndex(forwardBy: 4)

            // lengthSizeMinusOne + 1
            // bit(6) reserved, int(2) lengthSizeMinusOne, bit(3) reserved
            let nalUnitHeaderLength = try Int(parent.readInt(as: Int8.self) & 0x3 + 1)

            func readNalUnit(reader: inout ByteBuffer) throws -> Data {
                let length = try reader.readInt(as: Int16.self)
                return try reader.readData(count: Int(length))
            }

            let numbOfSpss = try parent.readInt(as: Int8.self) & 0x1F
            let sequenceParameterSets = try (0..<numbOfSpss).map { _ in try readNalUnit(reader: &parent) }

            let numOfPpss = try parent.readInt(as: Int8.self)
            let pictureParameterSets = try (0..<numOfPpss).map { _ in try readNalUnit(reader: &parent) }

            codecInfo = try CMVideoFormatDescription(
                h264ParameterSets: sequenceParameterSets + pictureParameterSets,
                nalUnitHeaderLength: nalUnitHeaderLength
            )
        }
    }

    struct AudioSampleEntry {
        let codecInfo: CMAudioFormatDescription?

        init(parent: inout ByteBuffer) throws {
            parent.moveReaderIndex(forwardBy: 28)
            let position = parent.readerIndex
            let childAtomSize = try parent.readInt(as: UInt32.self)
            let childAtomType = try MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))

            switch childAtomType {
            case .esds:
                parent.moveReaderIndex(to: position)
                let payload = try parent.readData(count: Int(childAtomSize))
                parent.moveReaderIndex(to: position + MP4Box.headerSize)
                codecInfo = try ESDescriptor(parent: &parent, box: payload).codecInfo
            default:
                codecInfo = nil
            }
        }
    }

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
