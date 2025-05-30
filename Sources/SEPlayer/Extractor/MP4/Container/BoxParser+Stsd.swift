//
//  BoxParser+Stsd.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMFormatDescription

extension BoxParser {
    struct StsdData {
        let description: Track.TrackFormat

        init(stsd: ByteBuffer, trackId: Int) throws {
            var stsd = stsd
            stsd.moveReaderIndex(to: Int(MP4Box.fullHeaderSize))
            let descriptionCount = try stsd.readInt(as: UInt32.self)
            var description: Track.TrackFormat?

            for _ in 0..<descriptionCount {
                let childStartPosition = stsd.readerIndex
                let childAtomSize = try stsd.readInt(as: UInt32.self)
                let childAtomType = try MP4Box.BoxType(rawValue: stsd.readInt(as: UInt32.self))

                if let childAtomType {
                    switch childAtomType {
                    case .avc1:
                        if let codecInfo = try? VideoSampleEntry(parent: &stsd, childAtomType: childAtomType).codecInfo {
                            description = .video(codecInfo)
                        }
                    case .mp4a:
                        if let codecInfo = try? AudioSampleEntry(parent: &stsd).codecInfo {
                            description = .video(codecInfo)
                        }
                    default:
                        break
                    }
                }

                stsd.moveReaderIndex(to: childStartPosition + Int(childAtomSize))
            }

            guard let description else {
                throw BoxParser.BoxParserErrors.badBoxContent(
                    type: .stsd, reason: "Sample Description Box missing valid description"
                )
            }

            self.description = description
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

    struct AudioSampleEntry {
        let codecInfo: CMAudioFormatDescription?

        init(parent: inout ByteBuffer) throws {
            parent.moveReaderIndex(forwardBy: 28)
            let childAtomSize = try parent.readInt(as: UInt32.self)
            let childAtomType = try MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))

            switch childAtomType {
            case .esds:
                try readFullboxExtra(reader: &parent)
                let payload = try parent.readData(count: Int(childAtomSize) - MP4Box.fullHeaderSize)
                codecInfo = try ESDescriptor(esdt: payload).codecInfo
            default:
                codecInfo = nil
            }
        }
    }
}
