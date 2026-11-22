//
//  BoxParser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.mp4.BoxParser
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import QuartzCore
import SEPlayerCommon

public struct BoxParser {
    public func parseTraks(
        moov: ContainerBox,
        gaplessInfoHolder: inout GaplessInfoHolder,
        durationTimeValue: CMTimeValue?,
        ignoreEditLists: Bool,
        isQuickTime: Bool,
        omitTrackSampleTable: Bool
    ) throws -> [TrackSampleTable] {
        let movieGaplessInfo = gaplessInfoHolder
        return try moov.containerChildren
            .filter { $0.type == .trak }
            .compactMap { atom in
                guard var track = try parseTrak(
                    trak: atom,
                    mvhd: moov.getLeafBoxOfType(type: .mvhd)
                        .checkNotNil(BoxParserErrors.missingBox(type: .mvhd)),
                    durationTimeValue: durationTimeValue,
                    ignoreEditLists: ignoreEditLists,
                    isQuickTime: isQuickTime
                ) else {
                    return nil
                }

                let stbl = try atom.getContainerBoxOfType(type: .mdia)
                    .checkNotNil(BoxParserErrors.missingBox(type: .mdia))
                    .getContainerBoxOfType(type: .minf)
                    .checkNotNil(BoxParserErrors.missingBox(type: .minf))
                    .getContainerBoxOfType(type: .stbl)
                    .checkNotNil(BoxParserErrors.missingBox(type: .stbl))

                var trackGaplessInfo = movieGaplessInfo
                MetadataUtil.setFormatGaplessInfo(gaplessInfoHolder: trackGaplessInfo, format: &track.format)
                let table = try parseStbl(
                    track: &track,
                    stblBox: stbl,
                    gaplessInfoHolder: &trackGaplessInfo,
                    omitTrackSampleTable: omitTrackSampleTable
                )
                if trackGaplessInfo.hasGaplessInfo { gaplessInfoHolder = trackGaplessInfo }
                return table
            }
    }

    func maybeSkipRemainingMetaBoxHeaderBytes(meta: inout BlockBufferReader) throws {
        var endPosition = meta.readerIndex
        // The next 8 bytes can be either:
        // (iso) [1 byte version + 3 bytes flags][4 byte size of next atom]
        // (qt)  [4 byte size of next atom      ][4 byte hdlr atom type   ]
        // In case of (iso) we need to skip the next 4 bytes.
        meta.moveReaderIndex(forwardBy: 4)
        if try meta.readInt(as: UInt32.self) != MP4Box.BoxType.hdlr.rawValue {
            endPosition += 4
        }
        meta.moveReaderIndex(to: endPosition)
    }

    private func parseTrak(
        trak: ContainerBox,
        mvhd: LeafBox,
        durationTimeValue: CMTimeValue?,
        ignoreEditLists: Bool,
        isQuickTime: Bool
    ) throws -> Track? {
        let mdia = try trak.getContainerBoxOfType(type: .mdia)
            .checkNotNil(BoxParserErrors.missingBox(type: .mdia))

        let trackType = try TrackType(rawValue: parseHdlr(
            hdlr: mdia.getLeafBoxOfType(type: .hdlr)
                .checkNotNil(BoxParserErrors.missingBox(type: .hdlr)).data
        ))

        guard trackType != .unknown else { return nil }

        let tkhdData = try TkhdData(
            tkhd: trak
                .getLeafBoxOfType(type: .tkhd)
                .checkNotNil(BoxParserErrors.missingBox(type: .tkhd)).data
        )
        let durationTimeValue = durationTimeValue ?? tkhdData.durationTimeValue
        let movieTimescale = try Mp4TimestampData(mvhd: mvhd.data).timescale

        let duration: CMTime = if let durationTimeValue {
            CMTime(value: durationTimeValue, timescale: movieTimescale)
        } else {
            .invalid
        }

        let stbl = try mdia.getContainerBoxOfType(type: .minf)
            .checkNotNil(BoxParserErrors.missingBox(type: .minf))
            .getContainerBoxOfType(type: .stbl)
            .checkNotNil(BoxParserErrors.missingBox(type: .stbl))

        let mdhdData = try MdhdData(mdhd: mdia
            .getLeafBoxOfType(type: .mdhd)
            .checkNotNil(BoxParserErrors.missingBox(type: .mdhd)).data)

        guard let stsd = stbl.getLeafBoxOfType(type: .stsd) else {
            throw BoxParserErrors.badBoxContent(type: .stbl, reason: "Sample table (stbl) missing sample description (stsd)")
        }

        let stsdData = try parseStsd(
            stsd: stsd.data,
            tkhdData: tkhdData,
            language: mdhdData.language,
            isQuickTime: isQuickTime
        )

        var editListDurations: [Int64]?
        var editListMediaTimes: [Int64]?

        if !ignoreEditLists, let edtsData = try EdtsData(edtsData: trak.getContainerBoxOfType(type: .edts)) {
            editListDurations = edtsData.editListDurations
            editListMediaTimes = edtsData.editListMediaTimes
        }

        if let format = stsdData.format {
            return Track(
                id: tkhdData.trackId,
                type: trackType,
                format: format,
                timescale: mdhdData.timescale,
                movieTimescale: movieTimescale,
                duration: duration,
                mediaDuration: mdhdData.mediaDuration,
                editListDurations: editListDurations,
                editListMediaTimes: editListMediaTimes,
                nalUnitLengthFieldLength: stsdData.nalUnitLengthFieldLength
            )
        } else {
            return nil
        }
    }

    private func parseStsd(
        stsd: BlockBufferReader,
        tkhdData: TkhdData,
        language: String,
        isQuickTime: Bool
    ) throws -> StsdData2 {
        var stsd = stsd
        stsd.moveReaderIndex(to: Int(MP4Box.fullHeaderSize))
        let numberOfEntries = try Int(stsd.readInt(as: UInt32.self))
        var out = StsdData2()

        let videoSampleEntries: Set<MP4Box.BoxType> = [
            .avc1, .avc3, .encv, .m1v_, .mp4v, .hvc1, .hev1, .s263, .H263, .h263, .vp08, .vp09, .av01, .dav1,
            .dvav, .dva1, .dvhe, .dvh1, .jpeg, .mjpg, .mp1v, .mp2v,
        ]
        let audioSampleEntries: Set<MP4Box.BoxType> = [
            .mp4a, .enca, .ac_3, .ec_3, .ac_4, .mlpa, .dtsc, .dtse, .dtsh, .dtsl, .dtsx, .samr, .sawb, .lpcm, .sowt,
            .twos, ._mp2, ._mp3, .mha1, .mhm1, .alac, .alaw, .ulaw, .Opus, .fLaC, .apac,
        ]
        let textSampleEntries: Set<MP4Box.BoxType> = [.TTML, .tx3g, .wvtt, .stpp, .c608, .mp4s]

        for _ in 0 ..< numberOfEntries {
            let childStartPosition = stsd.readerIndex
            let childAtomSize = try Int(stsd.readInt(as: UInt32.self))
            let rawChildAtomType = try stsd.readInt(as: UInt32.self)
            let childAtomType = MP4Box.BoxType(rawValue: rawChildAtomType)
            guard childAtomSize > 0 else {
                throw BoxParserErrors.badBoxContent(
                    type: childAtomType ?? .stsd,
                    reason: "childAtomSize must be positive"
                )
            }

            let isVideoSampleEntry = childAtomType.map { type in
                videoSampleEntries.contains(type) || MpegVideoUtil.mpeg2ProfileFormats.contains(type)
            } ?? false
            let isAudioSampleEntry = childAtomType.map(audioSampleEntries.contains) == true
                || AudioSampleEntry.isKnown(rawChildAtomType)

            if let childAtomType, isVideoSampleEntry {
                try parseVideoSampleEntry(
                    parent: &stsd,
                    atomType: childAtomType,
                    position: childStartPosition,
                    size: childAtomSize,
                    trackId: tkhdData.trackId,
                    rotation: Int(tkhdData.rotationDegrees),
                    isQuickTime: isQuickTime,
                    out: &out
                )
            } else if isAudioSampleEntry {
                try parseAudioSampleEntry(
                    parent: &stsd,
                    position: childStartPosition,
                    size: childAtomSize,
                    trackId: tkhdData.trackId,
                    language: language,
                    isQuickTime: isQuickTime,
                    out: &out
                )
            } else if let childAtomType, textSampleEntries.contains(childAtomType) {
                try parseTextSampleEntry(
                    parent: &stsd,
                    atomType: childAtomType,
                    position: childStartPosition,
                    atomSize: childAtomSize,
                    tkhdData: tkhdData,
                    language: language,
                    out: &out
                )
            } else {
                SELogger.debug(.mp4, "Skipping the unsupported sample entry \(rawChildAtomType.fourCharacterCode) of track \(tkhdData.trackId)")
            }

            stsd.moveReaderIndex(to: childStartPosition + childAtomSize)
        }

        return out
    }

    private func parseTextSampleEntry(
        parent: inout BlockBufferReader,
        atomType: MP4Box.BoxType,
        position: Int,
        atomSize: Int,
        tkhdData: TkhdData,
        language: String?,
        out: inout StsdData2
    ) throws {
        parent.moveReaderIndex(to: position + MP4Box.headerSize + StsdData2.headerSize)

        var format = TextFormat()
        switch atomType {
        case .TTML:
            format.codec = TextCodec(.applicationTTML)
        case .tx3g:
            let sampleDescriptionLength = atomSize - MP4Box.headerSize - 8
            let sampleEntry = try parent.getData(at: parent.readerIndex, length: sampleDescriptionLength)
            format.codec = TextCodec(.applicationTX3G, \.tx3g) { $0.sampleEntry = sampleEntry }
        case .wvtt:
            format.codec = TextCodec(.applicationMP4VTT)
        case .stpp:
            format.codec = TextCodec(.applicationTTML)
            // The times of its cues are those of the track.
            format.subsampleOffset = 0
        case .c608:
            format.codec = TextCodec(.applicationCEA608)
        default:
            // TODO: `mp4s` with an `esds` box, and an error for the others.
            return
        }

        format.id = String(tkhdData.trackId)
        format.language = language
        out.format = AnyFormat(format)
    }

    private func parseVideoSampleEntry(
        parent: inout BlockBufferReader,
        atomType: MP4Box.BoxType,
        position: Int,
        size: Int,
        trackId: Int,
        rotation: Int,
        isQuickTime: Bool,
        out: inout StsdData2
    ) throws {
        let entry = try parent.getSliceIgnoringReaderOffset(at: position, length: size)
        // Entries not read here are described by the system.
        let format = if let video = readVideoSampleEntry(entry, isQuickTime: isQuickTime) {
            try? video.format.with { format in try format.readCodec { type in video.boxes.payload(of: type) } }
        } else {
            (try? Self.systemVideoDescription(entry: entry, isQuickTime: isQuickTime))
                .flatMap { try? VideoFormat(formatDescription: $0) }
        }
        guard var format else {
            SELogger.debug(.mp4, "Skipping the video sample entry \(atomType.rawValue.fourCharacterCode) of track \(trackId)")
            return
        }

        // Profiles whose base layer other decoders can't show play as Dolby Vision. Others keep their HEVC base
        // layer, which any HEVC decoder shows.
        if var codec = format.codec, codec.mimeType == .videoH265, !codec.dolbyVision.isEmpty,
           !codec.dolbyVision.isBaseLayerCompatible {
            codec.mimeType = .videoDolbyVision
            format.codec = codec
        }
        if format.codec?.mimeType == .videoDolbyVision, format.transferFunction == nil {
            format.transferFunction = .pq
        }

        format.id = String(trackId)
        format.codecs = format.codec.flatMap { Self.videoCodecs($0, sampleEntryType: atomType) }
        format.rotation = rotation
        out.format = AnyFormat(format)
        out.nalUnitLengthFieldLength = format.codec.map(Self.nalUnitLengthSize) ?? 0
    }

    private func parseAudioSampleEntry(
        parent: inout BlockBufferReader,
        position: Int,
        size: Int,
        trackId: Int,
        language: String,
        isQuickTime: Bool,
        out: inout StsdData2
    ) throws {
        guard out.format == nil else { return }
        let entry = try parent.getSliceIgnoringReaderOffset(at: position, length: size)
        guard var (format, descriptor) = AudioSampleEntry.format(entry: entry, isQuickTime: isQuickTime) else {
            SELogger.debug(.mp4, "Skipping an audio sample entry of track \(trackId)")
            return
        }

        format.id = String(trackId)
        format.language = language
        format.codecs = descriptor?.codecs ?? format.codec.flatMap { Self.audioCodecs($0) }
        if let descriptor {
            format.averageBitrate = descriptor.averageBitrate > 0 ? descriptor.averageBitrate : nil
            format.peakBitrate = descriptor.maxBitrate > 0 ? descriptor.maxBitrate : nil
        }
        out.format = AnyFormat(format)
    }

    /// Reads a video sample entry into what a format description of it holds: the codec type, the size, and the
    /// extensions the fields and boxes of the entry describe.
    ///
    /// - Parameters:
    ///   - fullEntry: The whole sample entry, from its size field, its indices starting at 0.
    ///   - isQuickTime: Whether the file is a QuickTime movie rather than an ISO file.
    /// - Returns: `nil` for an entry not read here, such as one with a color table, or one that can't be read.
    private func readVideoSampleEntry(_ fullEntry: BlockBufferReader, isQuickTime: Bool) -> VideoSampleEntryData? {
        guard let header = try? VideoSampleEntryUtil.ImageDescriptionHeader(entry: fullEntry) else {
            return nil
        }
        let entry = header.entry
        let rawFormat = header.rawFormat
        // Uncompressed RGB names its codec by its depth, and an entry with a color table has one before its boxes.
        // The system reads those.
        guard MP4Box.BoxType(rawValue: rawFormat) != .raw_, header.colorTableID != 0, header.width > 0, header.height > 0, header.depth >= 0 else {
            return nil
        }

        var format = VideoFormat()
        format.size = VideoSize(width: header.width, height: header.height)
        let boxes = SampleEntryBox.boxes(in: entry, from: VideoSampleEntryUtil.headerSize).boxes
        guard let protection = VideoSampleEntryUtil.readBoxes(boxes, into: &format) else {
            return nil
        }

        var codecType = rawFormat
        if let type = MP4Box.BoxType(rawValue: rawFormat), MpegVideoUtil.mpeg2ProfileFormats.contains(type) {
            // Profiles of MPEG-2 named by their format, such as XDCAM, are MPEG-2 video of that profile.
            format.mpeg2Profile = FourCharacterCode(rawFormat)
            codecType = MP4Box.BoxType.mp2v.rawValue
        }
        format.sampleEntryFields = VisualSampleEntryFields(
            version: header.version,
            revisionLevel: header.revisionLevel,
            vendor: FourCharacterCode(header.vendor),
            temporalQuality: header.temporalQuality,
            spatialQuality: header.spatialQuality,
            compressorName: header.formatName,
            depth: header.depth
        )

        if MP4Box.BoxType(rawValue: rawFormat) == .mp4v {
            // The elementary stream descriptor tells the codec: MPEG-4 visual, or older MPEG video and JPEG.
            guard let esds = boxes.payload(of: .esds),
                  let descriptor = (try? esds.slice(from: esds.readerIndex + 4)).flatMap { ElementaryStreamDescriptor(esds: $0) },
                let type = MpegVideoUtil.codecType(descriptor: descriptor) else {
                return nil
            }
            codecType = type.rawValue
        } else if MP4Box.BoxType(rawValue: rawFormat) == .encv,
                  let protectedType = protection.lazy.compactMap(\.protectedVideoCodecType).first {
            // Protected video is named by its original format and scheme, as decoders of protected media know it.
            codecType = protectedType.rawValue
        }

        let codec = MP4Box.BoxType(rawValue: codecType)
        if let codec, let flavor = VideoSampleEntryUtil.ParameterSetFlavor(codecType: codec) {
            let config = boxes.payload(of: flavor.configType)
            guard VideoSampleEntryUtil.addParameterSetAttributes(to: &format, config: config, flavor: flavor) else {
                return nil
            }
        }
        if let codec, ProResUtil.formats.contains(codec) {
            VideoSampleEntryUtil.addProResAttributes(to: &format, codecType: codec, depth: header.depth)
        }
        if codec == .s263, boxes.payload(of: .d263) != nil {
            codecType = MP4Box.BoxType.h263.rawValue
        } else if codec == .mjpg, !isQuickTime {
            codecType = MP4Box.BoxType.jpeg.rawValue
        } else if let codec, let twin = VideoSampleEntryUtil.twinWithParameterSetsInConfig(of: codec, boxes: boxes) {
            codecType = twin.rawValue
        }
        format.codecType = FourCharacterCode(codecType)

        do {
            try format.setSampleEntry(entry, isQuickTime: isQuickTime)
            try format.keepBoxes(boxes)
        } catch {
            return nil
        }
        return VideoSampleEntryData(format: format, boxes: boxes)
    }

    private func parseHdlr(hdlr: BlockBufferReader) throws -> UInt32 {
        var hdlr = hdlr
        hdlr.moveReaderIndex(to: Int(MP4Box.fullHeaderSize) + 4)
        return try hdlr.readInt(as: UInt32.self)
    }
}

extension BoxParser {
    struct TkhdData {
        let trackId: Int
        let durationTimeValue: CMTimeValue?
        let rotationDegrees: CGFloat

        init(tkhd: BlockBufferReader) throws {
            var tkhd = tkhd
            tkhd.moveReaderIndex(to: Int(MP4Box.headerSize))
            let (version, _) = try BoxParser.readFullboxExtra(reader: &tkhd)
            tkhd.moveReaderIndex(forwardBy: version == 0 ? 8 : 16)
            trackId = try Int(tkhd.readInt(as: UInt32.self))
            tkhd.moveReaderIndex(forwardBy: 4)

            var durationUnknown = true
            let durationPosition = tkhd.readerIndex
            let durationByteCount = version == 0 ? 4 : 8
            let view = tkhd.readableBytesView
            for index in 0 ..< durationByteCount {
                if view[durationPosition + index] != 0xFF { // != -1
                    durationUnknown = false
                    break
                }
            }

            if durationUnknown {
                tkhd.moveReaderIndex(forwardBy: durationByteCount)
                durationTimeValue = nil
            } else {
                let value: Int64
                if version == 0 {
                    value = try Int64(tkhd.readInt(as: UInt32.self))
                } else {
                    let rawValue = try tkhd.readInt(as: UInt64.self)
                    guard rawValue <= UInt64(Int64.max) else {
                        throw BoxParserErrors.badBoxContent(type: .tkhd, reason: "Duration exceeds Int64.max")
                    }
                    value = Int64(rawValue)
                }
                if value == 0 {
                    // 0 duration normally indicates that the file is fully fragmented (i.e. all of the media
                    // samples are in fragments). Treat as unknown.
                    durationTimeValue = nil
                } else {
                    durationTimeValue = value
                }
            }

            tkhd.moveReaderIndex(forwardBy: 16)

            func int32() throws -> Int32 { try tkhd.readInt(as: Int32.self) }
            func fx16(_ v: Int32) -> CGFloat { CGFloat(v) / 65536.0 }
            func fx30(_ v: Int32) -> CGFloat { CGFloat(v) / 1073741824.0 } // 1<<30

            let a = try int32()
            let b = try int32()
            _ = try int32() // usually 0
            let c = try int32()
            let d = try int32()
            _ = try int32() // usually 0
            _ = try int32() // tx
            _ = try int32() // ty
            let w = try int32() // usually 1<<30 (i.e. 1.0)

            let aF = fx16(a)
            let bF = fx16(b)
            let cF = fx16(c)
            let dF = fx16(d)
            _ = fx30(w) // generally 1.0; not used below

            // Derive rotation in degrees from the 2×2 submatrix.
            // Normalize by scale to be robust if a/c include scale.
            let scaleX = sqrt(aF * aF + cF * cF)
            _ = sqrt(bF * bF + dF * dF)
            let na = scaleX > 0 ? aF / scaleX : aF
            let nb = scaleX > 0 ? bF / scaleX : bF
            let angle = atan2(nb, na) // radians
            var deg = angle * 180 / .pi
            // Snap very-near multiples of 90° to exact ints to avoid -89.999 -> -90
            let snapped = (deg / 90).rounded()
            if abs(deg - snapped * 90) < 0.01 { deg = snapped * 90 }
            if deg < 0 { deg += 360 }
            self.rotationDegrees = deg.truncatingRemainder(dividingBy: 360)
        }
    }

    struct MdhdData {
        let timescale: CMTimeScale
        let mediaDuration: CMTime
        let language: String

        init(mdhd: BlockBufferReader) throws {
            var mdhd = mdhd
            mdhd.moveReaderIndex(to: MP4Box.headerSize)
            let (version, _) = try BoxParser.readFullboxExtra(reader: &mdhd)
            mdhd.moveReaderIndex(forwardBy: version == 0 ? 8 : 16)
            timescale = try CMTimeScale(mdhd.readInt(as: UInt32.self))

            var mediaDurationUnknown = true
            let mediaDurationPosition = mdhd.readerIndex
            let mediaDurationByteCount = version == 0 ? 4 : 8
            let view = mdhd.readableBytesView
            for index in 0 ..< mediaDurationByteCount {
                if view[mediaDurationPosition + index] != 0xFF { // != -1
                    mediaDurationUnknown = false
                    break
                }
            }

            if mediaDurationUnknown {
                mdhd.moveReaderIndex(forwardBy: mediaDurationByteCount)
                mediaDuration = .invalid
            } else {
                let rawDuration: Int64
                if version == 1 {
                    rawDuration = try Int64(mdhd.readInt(as: UInt64.self))
                } else {
                    let d = try mdhd.readInt(as: UInt32.self)
                    rawDuration = d == UInt32.max ? Int64.max : Int64(d)
                }

                if rawDuration == .zero {
                    mediaDuration = .invalid
                } else {
                    mediaDuration = CMTime(value: rawDuration, timescale: timescale)
                }
            }

            let languageCode = try mdhd.readInt(as: UInt16.self)
            if let c1 = UnicodeScalar(((languageCode >> 10) & 0x1F) + 0x60),
               let c2 = UnicodeScalar(((languageCode >> 5) & 0x1F) + 0x60),
               let c3 = UnicodeScalar((languageCode & 0x1F) + 0x60) {
                language = String([Character(c1), Character(c2), Character(c3)])
            } else {
                language = "und"
            }
        }
    }

    struct EdtsData {
        let editListDurations: [Int64]
        let editListMediaTimes: [Int64]

        init?(edtsData: ContainerBox?) throws {
            guard var elst = edtsData?.getLeafBoxOfType(type: .elst)?.data else {
                return nil
            }

            elst.moveReaderIndex(to: MP4Box.headerSize)
            let (version, _) = try BoxParser.readFullboxExtra(reader: &elst)
            let entryCount = try elst.readInt(as: UInt32.self)

            var editListDurations = [Int64]()
            var editListMediaTimes = [Int64]()

            for _ in 0 ..< Int(entryCount) {
                let editListDuration = try version == 1 ? Int64(elst.readInt(as: UInt64.self)) : Int64(elst.readInt(as: UInt32.self))
                let editListMediaTime = try version == 1 ? elst.readInt(as: Int64.self) : Int64(elst.readInt(as: Int32.self))
                let mediaRateInteger = try elst.readInt(as: Int16.self)

                if mediaRateInteger != 1 {
                    throw BoxParserErrors.badBoxContent(type: .edts, reason: "Unsupported media rate.")
                }

                editListDurations.append(editListDuration)
                editListMediaTimes.append(editListMediaTime)
                elst.moveReaderIndex(forwardBy: 2)
            }

            self.editListDurations = editListDurations
            self.editListMediaTimes = editListMediaTimes
        }
    }

    /// A video sample entry read: the format of what it describes, and the boxes it keeps, read in place.
    struct VideoSampleEntryData {
        let format: VideoFormat
        let boxes: [SampleEntryBox]
    }

    struct StsdData2 {
        static let headerSize = 8
        var format: AnyFormat?
        var nalUnitLengthFieldLength: Int = 0

        init() {}
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
    static func readFullboxExtra(reader: inout BlockBufferReader) throws -> (version: UInt8, flags: UInt32) {
        let version = try reader.readInt(as: UInt8.self)
        let flagsA = try reader.readInt(as: UInt8.self)
        let flagsB = try reader.readInt(as: UInt8.self)
        let flagsC = try reader.readInt(as: UInt8.self)

        let flags = (UInt32(flagsA) << 16) | (UInt32(flagsB) << 8) | UInt32(flagsC)

        return (version: version, flags: flags)
    }

    static func readFullboxVersionNoFlags(reader: inout BlockBufferReader) throws -> UInt8 {
        let (version, flags) = try readFullboxExtra(reader: &reader)

        if flags != 0 {
            throw BoxParserErrors.flagsNotZeroInBoxExtra
        }

        return version
    }

    static func generateErrorIfNeeded(for violation: Bool, error: Error) throws {
        if violation { throw error }
    }

    func checkContainerInput(_ expression: Bool, _ message: String? = nil) throws(ParserError) {
        if !expression {
            throw ParserError.createForMalformedContainer(message: message)
        }
    }
}

extension TrackType {
    init(rawValue: UInt32) {
        switch rawValue {
        case 0x736f756e: // hdlr string soun
            self = .audio
        case 0x76696465: // hdlr string vide
            self = .video
        case 0x74657874, // hdlr string text
             0x7362746c, // hdlr string sbtl
             0x73756274, // hdlr string subt
             0x636c6370, // hdlr string clcp
             0x73756270: // hdlr string subp
            self = .text
        case 0x6d657461: // hdlr string meta
            self = .metadata
        default:
            self = .unknown
        }
    }
}
