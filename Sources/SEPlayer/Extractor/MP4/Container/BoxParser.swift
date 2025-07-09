//
//  BoxParser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMTime
import AudioToolbox

struct BoxParser {
    func parseTraks(
        moov: ContainerBox,
        gaplessInfoHolder: inout GaplessInfoHolder,
        duration: Int64,
        ignoreEditLists: Bool,
        isQuickTime: Bool
    ) throws -> [TrackSampleTable] {
        return try moov.containerChildren
            .filter { $0.type == .trak }
            .compactMap { atom in
                guard var track = try? parseTrak(
                    trak: atom,
                    mvhd: moov.getLeafBoxOfType(type: .mvhd)
                        .checkNotNil(BoxParserErrors.missingBox(type: .mvhd)),
                    duration: duration,
                    ignoreEditLists: ignoreEditLists,
                    isQuickTime: isQuickTime
                ) else { return nil }

                let stbl = try! atom.getContainerBoxOfType(type: .mdia)
                    .checkNotNil(BoxParserErrors.missingBox(type: .mdia))
                    .getContainerBoxOfType(type: .minf)
                    .checkNotNil(BoxParserErrors.missingBox(type: .minf))
                    .getContainerBoxOfType(type: .stbl)
                    .checkNotNil(BoxParserErrors.missingBox(type: .stbl))

                return try! parseStbl(track: &track, stblBox: stbl, gaplessInfoHolder: &gaplessInfoHolder)
            }
    }

    private func parseTrak(
        trak: ContainerBox,
        mvhd: LeafBox,
        duration: Int64,
        ignoreEditLists: Bool,
        isQuickTime: Bool
    ) throws -> Track? {
        var duration = duration
        let mdia = try! trak.getContainerBoxOfType(type: .mdia)
            .checkNotNil(BoxParserErrors.missingBox(type: .mdia))

        let trackType = try! TrackType(rawValue: parseHdlr(
                hdlr: mdia.getLeafBoxOfType(type: .hdlr)
                    .checkNotNil(BoxParserErrors.missingBox(type: .hdlr)).data
            )
        )

        guard trackType != .unknown else { return nil }

        let tkhdData = try! TkhdData(tkhd: trak
            .getLeafBoxOfType(type: .tkhd)
            .checkNotNil(BoxParserErrors.missingBox(type: .tkhd)).data
        )

        if duration == .timeUnset {
            duration = tkhdData.duration
        }

        let movieTimescale = try! Mp4TimestampData(mvhd: mvhd.data).timescale
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

        let stsdData = try parseStsd(
            stsd: stsd.data,
            trackId: tkhdData.trackId,
            rotationDegrees: tkhdData.rotationDegrees,
            language: mdhdData.language,
            isQuickTime: isQuickTime
        )

        var editListDurations: [Int64]?
        var editListMediaTimes: [Int64]?

        if !ignoreEditLists, let edtsData = try EdtsData(edtsData: trak.getContainerBoxOfType(type: .edts)) {
            editListDurations = edtsData.editListDurations
            editListMediaTimes = edtsData.editListMediaTimes
        }

        if let format = stsdData.format,
           let formatDescription = try format.buildFormatDescription() {
            return try Track(
                id: tkhdData.trackId,
                type: trackType,
                format: (formatDescription.mediaType == .video) ? .video(formatDescription) : .audio(formatDescription),
                timescale: mdhdData.timescale,
                movieTimescale: movieTimescale,
                durationUs: durationUs,
                mediaDurationUs: mdhdData.mediaDurationUs,
                editListDurations: editListDurations,
                editListMediaTimes: editListMediaTimes,
                format2: format
            )
        } else {
            return nil
        }
    }

    private func parseStsd(
        stsd: ByteBuffer,
        trackId: Int,
        rotationDegrees: Int,
        language: String,
        isQuickTime: Bool
    ) throws -> StsdData2 {
        var stsd = stsd
        stsd.moveReaderIndex(to: Int(MP4Box.fullHeaderSize))
        let numberOfEntries = try Int(stsd.readInt(as: UInt32.self))
        var out = StsdData2()

        let videoSampleEntries: [MP4Box.BoxType] = [.avc1, .avc3, .encv, .m1v_, .mp4v, .hvc1, .hev1, .s263, .H263, .vp08, .vp09, .av01, .dvav, .dva1, .dvhe, .dvh1]
        let audioSampleEntries: [MP4Box.BoxType] = [.mp4a, .enca, .ac_3, .ec_3, .ac_4, .mlpa, .dtsc, .dtse, .dtsh, .dtsl, .dtsx, .samr, .sawb, .lpcm, .sowt, .twos, ._mp2, ._mp3, .mha1, .mhm1, .alac, .alaw, .ulaw, .Opus, .fLaC]

        for index in 0..<numberOfEntries {
            let childStartPosition = stsd.readerIndex
            let childAtomSize = try Int(stsd.readInt(as: UInt32.self))
            let childAtomType = try MP4Box.BoxType(rawValue: stsd.readInt(as: UInt32.self))
            guard childAtomSize > 0 else {
                throw BoxParserErrors.badBoxContent(
                    type: childAtomType ?? .stsd,
                    reason: "childAtomSize must be positive"
                )
            }

            if let childAtomType {
                if videoSampleEntries.contains(childAtomType) {
                    try parseVideoSampleEntry(
                        parent: &stsd,
                        atomType: childAtomType,
                        position: childStartPosition,
                        size: childAtomSize,
                        trackId: trackId,
                        rotationDegrees: rotationDegrees,
                        out: &out,
                        entryIndex: index
                    )
                } else if audioSampleEntries.contains(childAtomType) {
                    try parseAudioSampleEntry(
                        parent: &stsd,
                        atomType: childAtomType,
                        position: childStartPosition,
                        size: childAtomSize,
                        trackId: trackId,
                        language: language,
                        isQuickTime: isQuickTime,
                        out: &out,
                        entryIndex: index
                    )
                }
            }

            stsd.moveReaderIndex(to: childStartPosition + childAtomSize)
        }

        return out
    }

    private func parseVideoSampleEntry(
        parent: inout ByteBuffer,
        atomType: MP4Box.BoxType,
        position: Int,
        size: Int,
        trackId: Int,
        rotationDegrees: Int,
        out: inout StsdData2,
        entryIndex: Int
    ) throws {
        parent.moveReaderIndex(to: position + MP4Box.headerSize + out.headerSize)
        parent.moveReaderIndex(forwardBy: 16)

        let width = try! parent.readInt(as: UInt16.self)
        let height = try! parent.readInt(as: UInt16.self)
        var pixelWidthHeightRatioFromPasp = false
        var pixelWidthHeightRatio: Float = 1
        // Set default luma and chroma bit depths to 8 as old codecs might not even signal them
        var bitdepthLuma = 8
        var bitdepthChroma = 8
        parent.moveReaderIndex(forwardBy: 50)

        var childPosition = parent.readerIndex
        if atomType == .encv { return }

        var mimeType: MimeTypes?
        // Maybe in the future
        if atomType == .m1v_ || atomType == .H263 {
            return
        }

        var initializationData: Format.InitializationData?
        var maxNumReorderSamples = Format.noValue

        while childPosition - position < size {
            parent.moveReaderIndex(to: childPosition)
            let childStartPosition = parent.readerIndex
            let childAtomSize = try Int(parent.readInt(as: UInt32.self))
            if childAtomSize == 0 && parent.readerIndex - position == size {
                // Handle optional terminating four zero bytes in MOV files.
                break
            }

            guard childAtomSize > 0 else {
                throw BoxParserErrors.badBoxContent(type: atomType, reason: "childAtomSize must be positive")
            }

            let bmffBox = try parent.getSliceIgnoringReaderOffset(at: childStartPosition, length: childAtomSize)
            let childAtomType = try MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))

            switch childAtomType {
            case .avcC:
                guard mimeType == nil else {
                    throw BoxParserErrors.badBoxContent(type: atomType, reason: "Invalid box content")
                }

                mimeType = .videoH264
                parent.moveReaderIndex(to: childStartPosition + MP4Box.headerSize)
                let avcConfig = try AvcConfig(data: &parent)
                initializationData = avcConfig
                out.nalUnitLengthFieldLength = avcConfig.nalUnitLengthFieldLength
                if !pixelWidthHeightRatioFromPasp {
                    pixelWidthHeightRatio = avcConfig.pixelWidthHeightRatio
                }
                bitdepthLuma = avcConfig.bitdepthLuma
                bitdepthChroma = avcConfig.bitdepthChroma
            case .pasp:
                pixelWidthHeightRatio = try parsePaspFrom(&parent, position: childStartPosition)
                pixelWidthHeightRatioFromPasp = true
            default:
                break
            }

            childPosition += childAtomSize
        }

        guard let mimeType else { return }

        let formatBuilder = Format.Builder()
            .setId(trackId)
            .setSampleMimeType(mimeType.rawValue)
            .setCodecs(nil)
            .setSize(width: Int(width), height: Int(height))
            .setPixelWidthHeightRatio(pixelWidthHeightRatio)
            .setRotationDegrees(rotationDegrees)
            .setInitializationData(initializationData)
            .setMaxNumReorderSamples(maxNumReorderSamples)
            .setMaxSubLayers(.zero)

        out.format = formatBuilder.build()
    }

    private func parsePaspFrom(_ parent: inout ByteBuffer, position: Int) throws -> Float {
        parent.moveReaderIndex(to: position + MP4Box.headerSize)
        let hSpacing = try parent.readInt(as: UInt32.self)
        let vSpacing = try parent.readInt(as: UInt32.self)
        return Float(hSpacing) / Float(vSpacing)
    }

    private func parseAudioSampleEntry(
        parent: inout ByteBuffer,
        atomType: MP4Box.BoxType,
        position: Int,
        size: Int,
        trackId: Int,
        language: String,
        isQuickTime: Bool,
        out: inout StsdData2,
        entryIndex: Int
    ) throws {
        parent.moveReaderIndex(to: position + MP4Box.headerSize + out.headerSize)

        var quickTimeSoundDescriptionVersion = 0
        if isQuickTime {
            quickTimeSoundDescriptionVersion = try Int(parent.readInt(as: UInt16.self))
            parent.moveReaderIndex(forwardBy: 6)
        } else {
            parent.moveReaderIndex(forwardBy: 8)
        }

        var channelCount = 0
        var sampleRate = 0
        var sampleRateMlp = 0
        var codecs: String?
        var esdsData: EsdsData?

        // TODO: in the future
        if quickTimeSoundDescriptionVersion == 0 || quickTimeSoundDescriptionVersion == 1 {
            channelCount = try Int(parent.readInt(as: UInt16.self))
            parent.moveReaderIndex(forwardBy: 6) // sampleSize, compressionId, packetSize.

            sampleRate = try parent.readFixedPoint16_16()
            // The sample rate has been redefined as a 32-bit value for Dolby TrueHD (MLP) streams.
            parent.moveReaderIndex(to: parent.readerIndex - 4)
            sampleRateMlp = try Int(parent.readInt(as: UInt32.self))

            if quickTimeSoundDescriptionVersion == 1 {
                parent.moveReaderIndex(forwardBy: 16)
            }
        } else if quickTimeSoundDescriptionVersion == 2 {
            return
        } else {
            return
        }

        var childPosition = parent.readerIndex
        // TODO: enca

        var mimeType: MimeTypes?
        var initializationData: Format.InitializationData?

        while childPosition - position < size {
            parent.moveReaderIndex(to: childPosition)
            let childAtomSize = try Int(parent.readInt(as: UInt32.self))
            guard childAtomSize > 0 else {
                throw BoxParserErrors.badBoxContent(type: atomType, reason: "childAtomSize must be positive")
            }

            let bmffBox = try parent.getSliceIgnoringReaderOffset(at: childPosition, length: childAtomSize)
            let childAtomType = try MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))

            if childAtomType == .esds || isQuickTime && childAtomType == .wave {
                let esdsAtomPosition = childAtomType == .esds
                    ? childPosition
                    : try findBoxPosition(parent: &parent, boxType: .esds, parentBoxPosition: childPosition, parentBoxSize: childAtomSize)

                if let esdsAtomPosition {
                    let esdsDataTest = try EsdsData(parent: &parent, position: esdsAtomPosition, size: childAtomSize)
                    esdsData = esdsDataTest
                    initializationData = esdsData
                    mimeType = esdsDataTest.mimeType
                }
            } else if childAtomType == .dOps {
                initializationData = try OpusData(parent: &parent)
                mimeType = .audioAAC
            }

            childPosition += childAtomSize
        }

        if out.format == nil, let mimeType {
            let formatBuilder = Format.Builder()
                .setId(trackId)
                .setSampleMimeType(mimeType.rawValue)
                .setCodecs(codecs)
                .setChannelCount(channelCount)
                .setSampleRate(sampleRate)
//                .setPcmEncoding(pcmEncoding)
                .setInitializationData(initializationData)
                .setLanguage(language)

            out.format = formatBuilder.build()
        }
    }

    private func parseHdlr(hdlr: ByteBuffer) throws -> UInt32 {
        var hdlr = hdlr
        hdlr.moveReaderIndex(to: Int(MP4Box.fullHeaderSize) + 4)
        return try! hdlr.readInt(as: UInt32.self)
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
            let (version, _) = try! BoxParser.readFullboxExtra(reader: &mvhd)
            if version == 0 {
                creationTimestampSeconds = try! Int64(mvhd.readInt(as: UInt32.self))
                modificationTimestampSeconds = try! Int64(mvhd.readInt(as: UInt32.self))
            } else {
                creationTimestampSeconds = try! Int64(mvhd.readInt(as: UInt64.self))
                modificationTimestampSeconds = try! Int64(mvhd.readInt(as: UInt64.self))
            }
            self.timescale = try! Int64(mvhd.readInt(as: UInt32.self))
        }
    }

    struct TkhdData {
        let trackId: Int
        let duration: Int64
        let rotationDegrees: Int

        init(tkhd: ByteBuffer) throws {
            var tkhd = tkhd
            tkhd.moveReaderIndex(to: Int(MP4Box.headerSize))
            let (version, _) = try BoxParser.readFullboxExtra(reader: &tkhd)
            tkhd.moveReaderIndex(forwardBy: version == 0 ? 8 : 16)
            trackId = try Int(tkhd.readInt(as: UInt32.self))
            tkhd.moveReaderIndex(forwardBy: 4)
            
            var durationUnknown = false
            let durationPosition = tkhd.readerIndex
            let durationByteCount = version == 0 ? 4 : 8
            let view = tkhd.readableBytesView
            for index in 0..<durationByteCount {
                if view[durationPosition + index] != 0xFF { // != -1
                    durationUnknown = false
                    break
                }
            }
            
            var duration: Int64
            if durationUnknown {
                tkhd.moveReaderIndex(forwardBy: durationByteCount)
                duration = .timeUnset
            } else {
                duration = version == 0 ? try Int64(tkhd.readInt(as: UInt32.self)) : try Int64(tkhd.readInt(as: UInt64.self))
                if duration == 0 {
                    // 0 duration normally indicates that the file is fully fragmented (i.e. all of the media
                    // samples are in fragments). Treat as unknown.
                    duration = .timeUnset
                }
            }
            self.duration = duration

            tkhd.moveReaderIndex(forwardBy: 16)
            let a00 = try Int(tkhd.readInt(as: Int32.self))
            let a01 = try Int(tkhd.readInt(as: Int32.self))
            tkhd.moveReaderIndex(forwardBy: 4)
            let a10 = try Int(tkhd.readInt(as: Int32.self))
            let a11 = try Int(tkhd.readInt(as: Int32.self))

            let fixedOne = 65536
            rotationDegrees = if a00 == 0 && a01 == fixedOne && a10 == -fixedOne && a11 == 0 {
                90
            } else if a00 == 0 && a01 == -fixedOne && a10 == fixedOne && a11 == 0 {
                270
            } else if a00 == -fixedOne && a01 == 0 && a10 == 0 && a11 == -fixedOne {
                180
            } else {
                // Only 0, 90, 180 and 270 are supported. Treat anything else as 0.
                .zero
            }
        }
    }

    struct MdhdData {
        let timescale: Int64
        let mediaDurationUs: Int64
        let language: String

        init(mdhd: ByteBuffer) throws {
            var mdhd = mdhd
            mdhd.moveReaderIndex(to: MP4Box.headerSize)
            let (version, _) = try BoxParser.readFullboxExtra(reader: &mdhd)
            mdhd.moveReaderIndex(forwardBy: version == 0 ? 8 : 16)
            timescale = try Int64(mdhd.readInt(as: UInt32.self))

            var mediaDurationUnknown = true
            let mediaDurationPosition = mdhd.readerIndex
            let mediaDurationByteCount = version == 0 ? 4 : 8
            let view = mdhd.readableBytesView
            for index in 0..<mediaDurationByteCount {
                if view[mediaDurationPosition + index] != 0xFF { // != -1
                    mediaDurationUnknown = false
                    break
                }
            }

            if mediaDurationUnknown {
                mdhd.moveReaderIndex(forwardBy: mediaDurationByteCount)
                mediaDurationUs = .timeUnset
            } else {
                let mediaDuration: Int64
                if version == 1 {
                    mediaDuration = try Int64(mdhd.readInt(as: UInt64.self))
                } else {
                    let d = try mdhd.readInt(as: UInt32.self)
                    mediaDuration = d == UInt32.max ? Int64.max : Int64(d)
                }

                if mediaDuration == .zero {
                    mediaDurationUs = .timeUnset
                } else {
                    mediaDurationUs = Util.scaleLargeTimestamp(
                        mediaDuration,
                        multiplier: .microsecondsPerSecond,
                        divisor: timescale
                    )
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

            for _ in 0..<Int(entryCount) {
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

    struct StsdData2 {
        let headerSize = 8
        var format: Format?
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
    static func readFullboxExtra(reader: inout ByteBuffer) throws -> (version: UInt8, flags: UInt32) {
        guard let version = reader.readInteger(as: UInt8.self),
              let flagsA = reader.readInteger(as: UInt8.self),
              let flagsB = reader.readInteger(as: UInt8.self),
              let flagsC = reader.readInteger(as: UInt8.self) else { throw BoxParserErrors.badBoxExtra }

        let flags = (UInt32(flagsA) << 16) | (UInt32(flagsB) << 8) | UInt32(flagsC)

        return (version: version, flags: flags)
    }

    static func readFullboxVersionNoFlags(reader: inout ByteBuffer) throws -> UInt8 {
        let (version, flags) = try! readFullboxExtra(reader: &reader)

        if flags != 0 {
            throw BoxParserErrors.flagsNotZeroInBoxExtra
        }

        return version
    }

    static func generateErrorIfNeeded(for violation: Bool, error: Error) throws {
        if violation { throw error }
    }

    private func findBoxPosition(
        parent: inout ByteBuffer, boxType: MP4Box.BoxType, parentBoxPosition: Int, parentBoxSize: Int
    ) throws -> Int? {
        var childAtomPosition = parent.readerIndex
        guard childAtomPosition >= parentBoxPosition else {
            throw ParserException(malformedContainer: "")
        }

        while childAtomPosition - parentBoxPosition < parentBoxSize {
            parent.moveReaderIndex(to: childAtomPosition)
            let childAtomSize = try Int(parent.readInt(as: UInt32.self))
            guard childAtomSize > 0 else {
                throw ParserException(malformedContainer: "childAtomSize must be positive")
            }

            let childAtomType = try MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))
            if childAtomType == boxType {
                return childAtomPosition
            }

            childAtomPosition += childAtomSize
        }

        return nil
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
