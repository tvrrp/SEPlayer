//
//  MpegVideoUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

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
        case 0x60, 0x61, 0x65: .mp2v
        case 0x6A: .mp1v
        case 0x6C: .jpeg
        default: nil
        }
    }
}
