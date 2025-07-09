//
//  BoxParser+Stsd.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMFormatDescription

extension BoxParser {
//    struct AudioSampleEntry {
//        let codecInfo: CMAudioFormatDescription?
//
//        init(parent: inout ByteBuffer) throws {
//            parent.moveReaderIndex(forwardBy: 28)
//            let childAtomSize = try! parent.readInt(as: UInt32.self)
//            let childAtomType = try! MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))
//
//            switch childAtomType {
//            case .esds:
//                try! readFullboxExtra(reader: &parent)
//                let payload = try! parent.readData(count: Int(childAtomSize) - MP4Box.fullHeaderSize)
//                codecInfo = try! ESDescriptor(esdt: payload).codecInfo
//            default:
//                codecInfo = nil
//            }
//        }
//    }
}
