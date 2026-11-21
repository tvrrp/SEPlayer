//
//  MpegVideoUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import Foundation
import SEPlayerCommon

/// Names the codecs of MPEG video sample entries: MPEG-2 formats named by their profile, and the visual streams of an
/// `mp4v` entry's elementary stream descriptor.
enum MpegVideoUtil {
    /// Formats of MPEG-2 video named by their profile and size, such as HDV and XDCAM, decoded as MPEG-2 video.
    static let mpeg2ProfileFormats: Set<MP4Box.BoxType> = [
        .hdv1, .hdv2, .hdv3, .hdv4, .hdv5, .hdv6, .hdv7, .hdv8, .hdv9, .hdva,
        .xdv1, .xdv2, .xdv3, .xdv4, .xdv5, .xdv6, .xdv7, .xdv8, .xdv9, .xdva, .xdvb, .xdvc, .xdvd, .xdve, .xdvf,
        .xd51, .xd54, .xd55, .xd59, .xd5a, .xd5b, .xd5c, .xd5d, .xd5e, .xd5f, .xdhd, .xdh2, .xfz1, .m2v1,
    ]

    /// The codec of an `mp4v` entry by the objectTypeIndication of its elementary stream descriptor, ISO/IEC 14496-1
    /// Table 5: MPEG-4 visual, MPEG-2 video, MPEG-1 video or JPEG.
    ///
    /// - Returns: `nil` for a stream of another kind.
    static func codecType(descriptor: ElementaryStreamDescriptor) -> MP4Box.BoxType? {
        switch descriptor.objectTypeIndication {
        case 0x20: .mp4v
        case 0x60,
             0x61,
             0x65: .mp2v
        case 0x6A: .mp1v
        case 0x6C: .jpeg
        default: nil
        }
    }
}

extension CodecAttributes where Scope == VideoCodec.MPEG4Visual {
    /// The attributes of the visual object sequence and video object layer headers of MPEG-4 Part 2, the
    /// DecoderSpecificInfo of an elementary stream descriptor.
    init(decoderSpecificInfo headers: BlockBufferReader) throws {
        self.init()
        self.decoderSpecificInfo = try headers.readableData()
        // A visual object sequence starts with its start code, 0x000001B0, then profile_and_level_indication.
        let isVisualObjectSequence = headers.readableBytes > 4
            && (try? headers.getInt(at: headers.readerIndex, as: UInt32.self)) == 0x0000_01B0
        if isVisualObjectSequence {
            self.profileAndLevel = try Int(headers.getInt(at: headers.readerIndex + 4, as: UInt8.self))
        }
    }
}
