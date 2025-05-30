//
//  BoxParser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMTime

struct BoxParser {
    func parseTraks(
        moov: ContainerBox,
        duration: Int64
    ) throws -> [TrackSampleTable] {
        return try moov.containerChildren
            .filter { $0.type == .trak }
            .compactMap { atom in
                guard let track = try? parseTrak(
                    trak: atom,
                    mvhd: moov.getLeafBoxOfType(type: .mvhd)
                        .checkNotNil(BoxParserErrors.missingBox(type: .mvhd)),
                    duration: duration
                ) else { return nil }

                let stbl = try atom.getContainerBoxOfType(type: .mdia)
                    .checkNotNil(BoxParserErrors.missingBox(type: .mdia))
                    .getContainerBoxOfType(type: .minf)
                    .checkNotNil(BoxParserErrors.missingBox(type: .minf))
                    .getContainerBoxOfType(type: .stbl)
                    .checkNotNil(BoxParserErrors.missingBox(type: .stbl))

                return try parseStbl(track: track, stblBox: stbl)
            }
    }

    func parseTrak(
        trak: ContainerBox,
        mvhd: LeafBox,
        duration: Int64
    ) throws -> Track? {
        var duration = duration
        let mdia = try trak.getContainerBoxOfType(type: .mdia)
            .checkNotNil(BoxParserErrors.missingBox(type: .mdia))

        let trackType = try TrackType(rawValue: parseHdlr(
                hdlr: mdia.getLeafBoxOfType(type: .hdlr)
                    .checkNotNil(BoxParserErrors.missingBox(type: .hdlr)).data
            )
        )

        guard trackType != .unknown else { return nil }

        let tkhdData = try TkhdData(tkhd: trak
            .getLeafBoxOfType(type: .tkhd)
            .checkNotNil(BoxParserErrors.missingBox(type: .tkhd)).data
        )

        if duration == .timeUnset {
            duration = tkhdData.duration
        }

        let movieTimescale = try Mp4TimestampData(mvhd: mvhd.data).timescale
        let durationUs: Int64 = if duration == .timeUnset {
            .timeUnset
        } else {
            Util.scaleLargeTimestamp(duration, multiplier: Int64.microsecondsPerSecond, divisor: movieTimescale)
        }

        let stbl = try mdia.getContainerBoxOfType(type: .minf)
            .checkNotNil(BoxParserErrors.missingBox(type: .minf))
            .getContainerBoxOfType(type: .stbl)
            .checkNotNil(BoxParserErrors.missingBox(type: .stbl))

        let mdhdData = try MdhdData(mdhd: mdia
            .getLeafBoxOfType(type: .mdhd)
            .checkNotNil(BoxParserErrors.missingBox(type: .mdhd)).data
        )

        guard let stsd = stbl.getLeafBoxOfType(type: .stsd) else {
            throw BoxParserErrors.badBoxContent(type: .stbl, reason: "Sample table (stbl) missing sample description (stsd)")
        }

        let stsdData = try StsdData(stsd: stsd.data, trackId: tkhdData.trackId)

        return Track(
            id: tkhdData.trackId,
            type: trackType,
            format: stsdData.description,
            timescale: mdhdData.timescale,
            movieTimescale: movieTimescale,
            durationUs: durationUs,
            mediaDurationUs: mdhdData.mediaDurationUs
        )
    }

    func parseHdlr(hdlr: ByteBuffer) throws -> UInt32 {
        var hdlr = hdlr
        hdlr.moveReaderIndex(to: Int(MP4Box.fullHeaderSize) + 4)
        return try hdlr.readInt(as: UInt32.self)
    }
}

extension BoxParser {
    struct Mp4TimestampData {
        let creationTimestampSeconds: Int64
        let modificationTimestampSeconds: Int64
        let timescale: Int64

        init(mvhd: ByteBuffer?) throws {
            guard var mvhd else { throw BoxParserErrors.missingBox(type: .mvhd) }
            mvhd.moveReaderIndex(to: Int(MP4Box.headerSize))
            let (version, _) = try BoxParser.readFullboxExtra(reader: &mvhd)
            if version == 0 {
                creationTimestampSeconds = try Int64(mvhd.readInt(as: UInt32.self))
                modificationTimestampSeconds = try Int64(mvhd.readInt(as: UInt32.self))
            } else {
                creationTimestampSeconds = try Int64(mvhd.readInt(as: UInt64.self))
                modificationTimestampSeconds = try Int64(mvhd.readInt(as: UInt64.self))
            }
            self.timescale = try Int64(mvhd.readInt(as: UInt32.self))
        }
    }

    struct TkhdData {
        let trackId: Int
        let duration: Int64

        init(tkhd: ByteBuffer) throws {
            var tkhd = tkhd
            tkhd.moveReaderIndex(to: Int(MP4Box.headerSize))
            let (version, _) = try BoxParser.readFullboxExtra(reader: &tkhd)
            tkhd.moveReaderIndex(forwardBy: version == 0 ? 8 : 16)
            trackId = try Int(tkhd.readInt(as: UInt32.self))
            tkhd.moveReaderIndex(forwardBy: 4)

            duration = if version == 1 {
                try Int64(tkhd.readInt(as: UInt64.self))
            } else {
                try Int64(tkhd.readInt(as: UInt32.self))
            }
        }
    }

    struct MdhdData {
        let timescale: Int64
        let mediaDurationUs: Int64

        init(mdhd: ByteBuffer) throws {
            var mdhd = mdhd
            mdhd.moveReaderIndex(to: MP4Box.headerSize)
            let (version, _) = try BoxParser.readFullboxExtra(reader: &mdhd)

            if version == 1 {
                mdhd.moveReaderIndex(forwardBy: 16)
                timescale = try Int64(mdhd.readInt(as: UInt32.self))
                mediaDurationUs = try Int64(mdhd.readInt(as: UInt64.self))
            } else {
                mdhd.moveReaderIndex(forwardBy: 8)
                timescale = try Int64(mdhd.readInt(as: UInt32.self))
                let d = try mdhd.readInt(as: UInt32.self)
                mediaDurationUs = d == UInt32.max ? Int64.max : Int64(d)
            }
        }
    }
}

extension BoxParser {
    enum BoxParserErrors: Error {
        case missingBox(type: MP4Box.BoxType)
        case badBoxExtra
        case flagsNotZeroInBoxExtra
        case contentIsMalformed(reason: String)
        case badBoxContent(type: MP4Box.BoxType, reason: String?)
    }
}

extension BoxParser {
    /// Parse the extra header fields for a full box.
    @discardableResult
    static func readFullboxExtra(reader: inout ByteBuffer) throws -> (version: UInt8, flags: UInt32) {
        guard let version = reader.readInteger(as: UInt8.self),
              let flagsA = reader.readInteger(as: UInt8.self),
              let flagsB = reader.readInteger(as: UInt8.self),
              let flagsC = reader.readInteger(as: UInt8.self) else { throw BoxParserErrors.badBoxExtra }

        let flags = (UInt32(flagsA) << 16) | (UInt32(flagsB) << 8) | UInt32(flagsC)

        return (version: version, flags: flags)
    }

    static func readFullboxVersionNoFlags(reader: inout ByteBuffer) throws -> UInt8 {
        let (version, flags) = try readFullboxExtra(reader: &reader)

        if flags != 0 {
            throw BoxParserErrors.flagsNotZeroInBoxExtra
        }

        return version
    }

    static func generateErrorIfNeeded(for violation: Bool, error: Error) throws {
        if violation { throw error }
    }
}

extension TrackType {
    init(rawValue: UInt32) {
        switch rawValue {
        case 0x76696465: // hdlr string vide
            self = .video
        case 0x736f756e: // hdlr string soun
            self = .audio
        default:
            self = .unknown
        }
    }
}
