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
//        let format: Format

        init(stsd: ByteBuffer, trackId: Int) throws {
            var stsd = stsd
            stsd.moveReaderIndex(to: Int(MP4Box.fullHeaderSize))
            let descriptionCount = try! stsd.readInt(as: UInt32.self)
            var description: Track.TrackFormat?

            for index in 0..<descriptionCount {
                let childStartPosition = stsd.readerIndex
                let childAtomSize = try! stsd.readInt(as: UInt32.self)
                let childAtomType = try! MP4Box.BoxType(rawValue: stsd.readInt(as: UInt32.self))

                if let childAtomType {
                    switch childAtomType {
                    case .avc1:
                        if let codecInfo = try! VideoSampleEntry(
                            parent: &stsd,
                            childAtomType: childAtomType,
                            size: Int(childAtomSize),
                            trackId: trackId,
                            rotationDegrees: .zero, // TODO: rotationDegrees
                            entryIndex: Int(index)
                        ).codecInfo {
                            description = .video(codecInfo)
                        }
                    case .mp4a:
                        if let codecInfo = try! AudioSampleEntry(parent: &stsd).codecInfo {
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

        init(
            parent: inout ByteBuffer,
            childAtomType: MP4Box.BoxType,
            size: Int,
            trackId: Int,
            rotationDegrees: Int,
            entryIndex: Int
        ) throws {
//            let position = parent.readerIndex
//            parent.moveReaderIndex(to: position + MP4Box.headerSize + StsdData.headerSize)
//            parent.moveReaderIndex(forwardBy: 16)
//
//            let width = try! parent.readInt(as: UInt16.self)
//            let height = try! parent.readInt(as: UInt16.self)
//            var pixelWidthHeightRatioFromPasp = false
//            var pixelWidthHeightRatio: Float = 1
//            let bitdepthLuma = 8
//            let bitdepthChroma = 8
//            parent.moveReaderIndex(forwardBy: 50)
//
//            let childPosition = parent.readerIndex
//            // TODO: encv
//
//            var mimeType: MimeTypes?
//            var codecInfo: CMFormatDescription?
//            // Maybe in the future
//            if childAtomType == .m1v_ || childAtomType == .H263 {
//                self.codecInfo = nil
//                return
//            }
//
//            while childPosition - position < size {
//                parent.moveReaderIndex(to: childPosition)
//                let childStartPosition = parent.readerIndex
//                let childAtomSize = try! Int(parent.readInt(as: Int32.self))
//                if childAtomSize == 0 && parent.readerIndex - position == size {
//                    break
//                }
//
//                guard childAtomSize > 0 else {
//                    throw BoxParserErrors.badBoxContent(type: childAtomType, reason: "childAtomSize must be positive")
//                }
//
//                switch childAtomType {
//                case .avcC:
//                    guard mimeType == nil else {
//                        throw BoxParserErrors.badBoxContent(type: childAtomType, reason: "Invalid box content")
//                    }
//
//                    mimeType = .videoH264
//                    parent.moveReaderIndex(to: childStartPosition + MP4Box.headerSize)
//                    let avcConfig = try! AVCCodecInfo(parent: &parent)
//                    break
//                default:
//                    codecInfo = nil
//                    break
//                }
//            }
//
//            self.codecInfo = codecInfo
//            // Skip all metadata
            parent.moveReaderIndex(forwardBy: 78 + MP4Box.boxSize)
            let childAtomType = try! MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))

            switch childAtomType {
            case .avcC:
                codecInfo = try! AVCCodecInfo(parent: &parent).codecInfo
            default:
                codecInfo = nil
            }
//            fatalError()
        }
    }

    struct AudioSampleEntry {
        let codecInfo: CMAudioFormatDescription?

        init(parent: inout ByteBuffer) throws {
            parent.moveReaderIndex(forwardBy: 28)
            let childAtomSize = try! parent.readInt(as: UInt32.self)
            let childAtomType = try! MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))

            switch childAtomType {
            case .esds:
                try! readFullboxExtra(reader: &parent)
                let payload = try! parent.readData(count: Int(childAtomSize) - MP4Box.fullHeaderSize)
                codecInfo = try! ESDescriptor(esdt: payload).codecInfo
            default:
                codecInfo = nil
            }
        }
    }
}

extension BoxParser.StsdData {
    static let headerSize: Int = 8
}
