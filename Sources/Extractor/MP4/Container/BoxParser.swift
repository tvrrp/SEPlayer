//
//  BoxParser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

// swiftlint:disable file_length

import AudioToolbox
import CoreMedia.CMTime
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
        try moov.containerChildren
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

                return try parseStbl(
                    track: &track,
                    stblBox: stbl,
                    gaplessInfoHolder: &gaplessInfoHolder,
                    omitTrackSampleTable: omitTrackSampleTable
                )
            }
    }

    func parseUdta(udtaBox: LeafBox) throws -> Metadata {
        var udtaData = udtaBox.data
        udtaData.moveReaderIndex(to: MP4Box.headerSize)
        return Metadata()
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

        for index in 0 ..< numberOfEntries {
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
                || AudioSampleEntryUtil.reads(rawChildAtomType)

            if let childAtomType, isVideoSampleEntry {
                try parseVideoSampleEntry(
                    parent: &stsd,
                    atomType: childAtomType,
                    position: childStartPosition,
                    size: childAtomSize,
                    trackId: tkhdData.trackId,
                    rotationDegrees: tkhdData.rotationDegrees,
                    transform3D: tkhdData.transform3D,
                    isQuickTime: isQuickTime,
                    out: &out,
                    entryIndex: index
                )
            } else if isAudioSampleEntry {
                try parseAudioSampleEntry(
                    parent: &stsd,
                    position: childStartPosition,
                    size: childAtomSize,
                    trackId: tkhdData.trackId,
                    language: language,
                    isQuickTime: isQuickTime,
                    out: &out,
                    entryIndex: index
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

        var initializationData: (any Format.InitializationData)?
        var subsampleOffset = Format.offsetSampleRelative // TODO: make as func to properly compare because need to use CMTime.isPositiveInfinity

        var mimeType: MimeTypes?

        if atomType == .TTML {
            mimeType = .applicationTTML
        } else if atomType == .tx3g {
            mimeType = .applicationTX3G
            let sampleDescriptionLength = atomSize - MP4Box.headerSize - 8
            let slice = try parent.getSlice(at: parent.readerIndex, length: sampleDescriptionLength)
            initializationData = Format.ByteBufferInitializationData(byteBuffer: [slice])
        } else if atomType == .wvtt {
            mimeType = .applicationMP4VTT
        } else if atomType == .stpp {
            mimeType = .applicationTTML
            subsampleOffset = .zero
        } else if atomType == .c608 {
            mimeType = .applicationCEA608
            // TODO: out.requiredSampleTransformation
        } else if atomType == .mp4s {
            let position = parent.readerIndex
            parent.moveReaderIndex(forwardBy: 4) // child atom size
            let childAtomType = try MP4Box.BoxType(rawValue: parent.readInt(as: UInt32.self))
            if childAtomType == .esds {
//                let esds = try parseEs
                // TODO: parseEsdsData
            }
            return
        } else {
            // TODO: need to throw error
            return
        }

        if let mimeType {
            out.format = Format.Builder()
                .setId(tkhdData.trackId)
                .setSampleMimeType(mimeType)
                .setLanguage(language)
                .setSubsampleOffset(subsampleOffset)
                .setInitializationData(initializationData)
                .build()
        }
    }

    private func parseVideoSampleEntry(
        parent: inout BlockBufferReader,
        atomType: MP4Box.BoxType,
        position: Int,
        size: Int,
        trackId: Int,
        rotationDegrees: CGFloat,
        transform3D: CATransform3D,
        isQuickTime: Bool,
        out: inout StsdData2,
        entryIndex: Int
    ) throws {
        parent.moveReaderIndex(to: position + MP4Box.headerSize + StsdData2.headerSize)
        parent.moveReaderIndex(forwardBy: 16)

        let width = try parent.readInt(as: UInt16.self)
        let height = try parent.readInt(as: UInt16.self)
        var pixelWidthHeightRatioFromPasp = false
        var pixelWidthHeightRatio: Float = 1
        // Set default luma and chroma bit depths to 8 as old codecs might not even signal them
        var bitdepthLuma = 8
        var bitdepthChroma = 8
        parent.moveReaderIndex(forwardBy: 50)

        var childPosition = parent.readerIndex

        var mimeType: MimeTypes?

        var initializationData: (any Format.InitializationData)?
        var codecs: String?
        let maxNumReorderSamples = Format.noValue
        let usesParameterSetsInBand = atomType == .hev1 || atomType == .dvhe
        var hevcConfig: HevcUtil.Configuration?
        var dolbyVisionConfig: DolbyVisionUtil.Configuration?
        var colorInfo: ColorInfo?
        // The range the codec's config tells, for codecs whose parameter sets aren't read here.
        var configVideoRange: Format.VideoRange?

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
                codecs = avcConfig.codecs
                bitdepthLuma = avcConfig.bitdepthLuma
                bitdepthChroma = avcConfig.bitdepthChroma
            case .pasp:
                pixelWidthHeightRatio = try parsePaspFrom(&parent, position: childStartPosition)
                pixelWidthHeightRatioFromPasp = true
            case .hvcC:
                guard mimeType == nil else {
                    throw BoxParserErrors.badBoxContent(type: atomType, reason: "Invalid box content")
                }
                mimeType = .videoH265
                parent.moveReaderIndex(to: childStartPosition + MP4Box.headerSize)
                let config = try HevcUtil.Configuration(reader: &parent, sampleEntryType: usesParameterSetsInBand ? .hev1 : .hvc1)
                hevcConfig = config
                out.nalUnitLengthFieldLength = config.nalUnitLengthFieldLength
                codecs = config.codecs
                bitdepthLuma = config.bitdepthLuma
                bitdepthChroma = config.bitdepthChroma
            case .dvcC,
                 .dvvC,
                 .dvwC:
                parent.moveReaderIndex(to: childStartPosition + MP4Box.headerSize)
                dolbyVisionConfig = try DolbyVisionUtil.Configuration(reader: &parent)
            case .colr:
                parent.moveReaderIndex(to: childStartPosition + MP4Box.headerSize)
                colorInfo = try ColorInfo(reader: &parent)
            case .vpcC:
                if let vpc = try VpcConfiguration(vpcC: bmffBox.slice(from: MP4Box.headerSize)) {
                    codecs = vpc.codecs(sampleEntryType: atomType == .encv ? .vp09 : atomType)
                    configVideoRange = vpc.videoRange
                }
            case .av1C:
                if let av1 = try Av1Configuration(av1C: bmffBox.slice(from: MP4Box.headerSize)) {
                    codecs = av1.codecs
                    configVideoRange = av1.videoRange
                }
            default:
                break
            }

            childPosition += childAtomSize
        }

        let entry = try parent.getSliceIgnoringReaderOffset(at: position, length: size)
        let video = readVideoSampleEntry(entry, isQuickTime: isQuickTime)
        if let video, let avcConfig = initializationData as? AvcConfig, avcConfig.hasParameterSets {
            initializationData = SampleEntryFormatDescription(formatDescription: video.formatDescription)
        }

        var videoRange = colorInfo?.videoRange ?? .unknown
        if let hevcConfig {
            if let video {
                initializationData = SampleEntryFormatDescription(formatDescription: video.formatDescription)
            } else {
                // Entries not read here are described by the system.
                initializationData = try CoreMediaParsedVideo(entry: entry, isQuickTime: isQuickTime)
            }

            if let dolbyVisionConfig {
                // Dolby Vision entries, and profiles whose base layer other decoders can't show, play as Dolby Vision.
                // Others keep their HEVC base layer, which any HEVC decoder shows.
                if atomType == .dvh1 || atomType == .dvhe || !dolbyVisionConfig.isBaseLayerCompatible {
                    mimeType = .videoDolbyVision
                    codecs = dolbyVisionConfig.codecs(sampleEntryType: usesParameterSetsInBand ? .dvhe : .dvh1)
                }
                if colorInfo == nil { videoRange = .pq }
            }
        }

        guard let mimeType else {
            // Codecs without a config read here take their format from the description of the entry.
            if let video {
                out.format = videoFormat(
                    video,
                    trackId: trackId,
                    codecs: codecs,
                    pixelWidthHeightRatio: pixelWidthHeightRatio,
                    rotationDegrees: rotationDegrees,
                    transform3D: transform3D,
                    videoRange: colorInfo?.videoRange ?? configVideoRange ?? videoRange
                )
            } else {
                _ = try? CoreMediaParsedVideo.create(
                    parent: &parent,
                    position: position,
                    size: size,
                    trackId: trackId,
                    rotationDegrees: rotationDegrees,
                    transform3D: transform3D,
                    isQuickTime: isQuickTime,
                    out: &out,
                    entryIndex: entryIndex
                )
            }
            return
        }

        let formatBuilder = Format.Builder()
            .setId(trackId)
            .setSampleMimeType(mimeType)
            .setCodecs(codecs)
            .setSize(width: Int(width), height: Int(height))
            .setPixelWidthHeightRatio(pixelWidthHeightRatio)
            .setRotationDegrees(rotationDegrees)
            .setTransform3D(transform3D)
            .setInitializationData(initializationData)
            .setMaxNumReorderSamples(maxNumReorderSamples)
            .setMaxSubLayers(hevcConfig?.maxSubLayers ?? .zero)
            .setVideoRange(videoRange)

        out.format = formatBuilder.build()
    }

    private func parseAudioSampleEntry(
        parent: inout BlockBufferReader,
        position: Int,
        size: Int,
        trackId: Int,
        language: String,
        isQuickTime: Bool,
        out: inout StsdData2,
        entryIndex: Int
    ) throws {
        let entry = try parent.getSliceIgnoringReaderOffset(at: position, length: size)
        guard out.format == nil, let audio = readAudioSampleEntry(entry, isQuickTime: isQuickTime) else {
            // Formats not read here, and protected media, are described by the system.
            _ = try? CoreMediaParsedAudio.create(
                parent: &parent,
                position: position,
                size: size,
                trackId: trackId,
                language: language,
                isQuickTime: isQuickTime,
                out: &out,
                entryIndex: entryIndex
            )
            return
        }

        out.format = audioFormat(audio, trackId: trackId, language: language)
    }

    /// Reads an audio sample entry into the format description decoders need: the stream description, the channel
    /// layout, the magic cookie, and the entry itself with the boxes nothing here reads.
    ///
    /// - Parameters:
    ///   - entry: The whole sample entry, from its size field, its indices starting at 0.
    ///   - isQuickTime: Whether the file is a QuickTime movie rather than an ISO file.
    /// - Returns: `nil` for an entry of a format not read here, or one that can't be read.
    private func readAudioSampleEntry(_ entry: BlockBufferReader, isQuickTime: Bool) -> AudioSampleEntryData? {
        guard let sound = SoundDescription(entry: entry, isQuickTime: isQuickTime),
              var boxes = sound.readBoxes(isQuickTime: isQuickTime) else {
            return nil
        }

        // Protected media is described as the codec its config box names, whatever the `frma` box says; the format
        // of protected media then replaces the codec's.
        let protection = boxes.sinf.map { ProtectionScheme(sinf: $0.payload) }
        let isProtected = sound.format == .enca
        var rawFormat = sound.rawFormat
        var registeredCodec: AudioSampleEntryUtil.RegisteredCodec?
        if isProtected {
            guard boxes.dOps == nil else {
                return nil
            }
            if let codec = AudioSampleEntryUtil.protectedCodec(boxes: boxes) {
                rawFormat = codec.rawValue
            } else {
                registeredCodec = AudioSampleEntryUtil.RegisteredCodec(boxes: boxes.unknown, isQuickTime: isQuickTime)
            }
        } else if !AudioSampleEntryUtil.reads(sound.rawFormat) {
            // Codecs known by their config box, such as APAC.
            guard let codec = AudioSampleEntryUtil.RegisteredCodec(boxes: boxes.unknown, isQuickTime: isQuickTime) else {
                return nil
            }
            registeredCodec = codec
        }
        if let registeredCodec {
            rawFormat = registeredCodec.format
            boxes.unknown.remove(at: registeredCodec.configBoxIndex)
        }

        let esds = boxes.esds.flatMap { try? $0.payload.slice(from: 4) }
        let descriptor = esds.flatMap { ElementaryStreamDescriptor(esds: $0, readsClockReference: false) }
        let opusHead = boxes.dOps.flatMap { OpusUtil.magicCookie(dOps: $0.box) }

        guard var cookie = AudioSampleEntryUtil.magicCookie(
            format: rawFormat,
            boxes: boxes,
            esds: esds,
            opusHead: opusHead,
            isQuickTime: isQuickTime
        ), var description = AudioSampleEntryUtil.sampleEntryDescription(
            sound: sound,
            format: rawFormat,
            boxes: boxes,
            isQuickTime: isQuickTime
        ) else {
            return nil
        }
        if let registeredCodec { cookie.reader = registeredCodec.magicCookie }

        switch MP4Box.BoxType(rawValue: description.mFormatID) {
        case ._mp3? where sound.usesQuickTimeBoxes:
            break
        case .MAC3?:
            description.mBytesPerPacket = description.mChannelsPerFrame * 2
            description.mFramesPerPacket = 6
        case .MAC6?:
            description.mBytesPerPacket = description.mChannelsPerFrame
            description.mFramesPerPacket = 6
        case .ac_3?:
            if let dac3 = boxes.dac3 {
                guard let ac3 = Ac3Util.ac3StreamDescription(dac3: dac3.box) else {
                    return nil
                }
                description = ac3
            }
        case .ec_3?:
            guard let dec3 = boxes.dec3, let (eac3, _) = Ac3Util.eac3Configuration(dec3: dec3.box) else {
                return nil
            }
            description = eac3
        case .alac?:
            if let alac = boxes.alac {
                guard let lossless = AlacUtil.streamDescription(alac: alac.box) else {
                    return nil
                }
                description = lossless
            }
        case .fLaC?,
             .flac?:
            description.mFormatID = kAudioFormatFLAC
            if let dfLa = boxes.dfLa {
                guard let flac = FlacUtil.streamDescription(dfLa: dfLa.box, sampleEntryDescription: description) else {
                    return nil
                }
                description = flac
            }
        case .ipcm?,
             .fpcm?:
            let isFloat = description.mFormatID == MP4Box.BoxType.fpcm.rawValue
            description.mFormatID = kAudioFormatLinearPCM
            if let pcmC = boxes.pcmC {
                guard let pcm = PcmUtil.streamDescription(
                    pcmC: pcmC.box,
                    isFloat: isFloat,
                    sampleRate: description.mSampleRate,
                    channelCount: Int(description.mChannelsPerFrame)
                ) else {
                    return nil
                }
                description = pcm
            }
        case .lpcm?:
            break
        case .mp4a?,
             .m4ae?:
            if let esds {
                guard let (mpeg4, mpeg4Cookie) = Mpeg4AudioUtil.streamDescription(
                    esds: esds,
                    descriptor: descriptor,
                    sampleEntryDescription: description
                ) else {
                    return nil
                }
                description = mpeg4
                cookie.reader = mpeg4Cookie
            } else {
                description.mFormatID = kAudioFormatMPEG4AAC
                description.mFramesPerPacket = 1024
            }
        case .samr?,
             .sawb?:
            guard let format = MP4Box.BoxType(rawValue: description.mFormatID), let amrCookie = cookie.reader,
                  let amr = AmrUtil.streamDescription(format: format, magicCookie: amrCookie) else {
                return nil
            }
            description = amr
        default:
            // The decoder completes the fields of the entry from the codec's config, such as Opus's frame size.
            if let opusHead {
                guard let opus = OpusUtil.streamDescription(magicCookie: opusHead, sampleEntryDescription: description) else {
                    return nil
                }
                description = opus
            }
            if let completed = try? AudioFormatProperties.formatInfo(description: description, magicCookie: cookie.reader) {
                description = completed
            }
        }

        guard let explicitLayout = AudioSampleEntryUtil.explicitLayout(boxes: boxes, description: description) else {
            return nil
        }

        var extensions = SampleDescriptionExtensions()
        do {
            try extensions.setVerbatimEntry(entry, isQuickTime: isQuickTime)
            if let protection { try protection.addExtensions(to: &extensions) }
        } catch {
            return nil
        }
        boxes.unknown.forEach { extensions.addUnknownBox($0) }

        let fallbackLayout: () -> ManagedAudioChannelLayout? = {
            if let layout = descriptor.flatMap(Mpeg4AudioUtil.channelLayout(descriptor:)) {
                return layout
            }
            guard explicitLayout.layout == nil, cookie.reader != nil else {
                return nil
            }
            if description.mFormatID == kAudioFormatAC3, let dac3 = boxes.dac3 {
                return Ac3Util.ac3ChannelLayout(dac3: dac3.box)
            }
            if description.mFormatID == kAudioFormatEnhancedAC3, let dec3 = boxes.dec3,
               let (_, layout) = Ac3Util.eac3Configuration(dec3: dec3.box) {
                return ManagedAudioChannelLayout(tag: layout.tag)
            }
            return nil
        }

        guard let builtExtensions = try? extensions.build(),
              var (description, layout) = try? AudioSampleEntryUtil.resolveDescription(
                  description: description,
                  magicCookie: cookie.reader,
                  explicitLayout: explicitLayout.layout,
                  fallbackLayout: fallbackLayout
              ) else {
            return nil
        }

        if isProtected {
            if rawFormat != sound.rawFormat {
                guard let protectedFormat = ProtectionScheme.protectedAudioFormat(description.mFormatID) else {
                    return nil
                }
                description.mFormatID = protectedFormat
                guard let protectedCookie = AudioSampleEntryUtil.protectedMagicCookie(boxes: boxes, esds: esds) else {
                    return nil
                }
                if let protectedCookie = protectedCookie.reader ?? registeredCodec?.magicCookie {
                    cookie.reader = protectedCookie
                }
            } else {
                // Protected media of a codec without a config, such as linear PCM, has no cookie.
                cookie.reader = nil
            }
        }

        guard let formatDescription = try? CMFormatDescription(
            audioStreamBasicDescription: description,
            layout: layout,
            magicCookie: cookie.reader,
            extensions: builtExtensions
        ) else {
            return nil
        }

        return AudioSampleEntryData(
            formatDescription: formatDescription,
            streamDescription: description,
            elementaryStreamDescriptor: descriptor
        )
    }

    /// Reads a video sample entry into the format description decoders need: the codec, the size, and the
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
        let format = MP4Box.BoxType(rawValue: rawFormat)
        // Uncompressed RGB names its codec by its depth, and an entry with a color table has one before its boxes.
        // The system reads those.
        guard format != .raw_, header.colorTableID != 0, header.width > 0, header.height > 0, header.depth >= 0 else {
            return nil
        }

        var extensions = SampleDescriptionExtensions()
        let boxes = SampleEntryBox.boxes(in: entry, from: VideoSampleEntryUtil.headerSize).boxes
        guard let protection = VideoSampleEntryUtil.readBoxes(boxes, into: &extensions) else {
            return nil
        }

        var codecType = rawFormat
        if let format, MpegVideoUtil.mpeg2ProfileFormats.contains(format) {
            extensions[SampleDescriptionExtensionKey.conformsToMPEG2VideoProfile] =
                SampleDescriptionExtensions.number(Int32(bitPattern: rawFormat))
            codecType = MP4Box.BoxType.mp2v.rawValue
        }

        do {
            try extensions.setVerbatimEntry(entry, isQuickTime: isQuickTime)
        } catch {
            return nil
        }
        extensions[SampleDescriptionExtensionKey.formatName] = header.formatName
        extensions[SampleDescriptionExtensionKey.version] = SampleDescriptionExtensions.number(header.version)
        extensions[SampleDescriptionExtensionKey.revisionLevel] = SampleDescriptionExtensions.number(header.revisionLevel)
        extensions[SampleDescriptionExtensionKey.temporalQuality] = SampleDescriptionExtensions.number(header.temporalQuality)
        extensions[SampleDescriptionExtensionKey.spatialQuality] = SampleDescriptionExtensions.number(header.spatialQuality)
        if header.vendor != 0 {
            extensions[SampleDescriptionExtensionKey.vendor] = header.vendor.fourCharacterCode
        }
        if header.depth != 0 {
            extensions[SampleDescriptionExtensionKey.depth] = SampleDescriptionExtensions.number(Int16(header.depth))
        }

        if format == .mp4v {
            // The elementary stream descriptor tells the codec: MPEG-4 visual, or older MPEG video and JPEG.
            guard let esds = extensions.unknownBoxPayloads(of: .esds).first,
                  let descriptor = (try? esds.slice(from: esds.readerIndex + 4)).flatMap { ElementaryStreamDescriptor(esds: $0) },
                let type = MpegVideoUtil.codecType(descriptor: descriptor) else {
                return nil
            }
            codecType = type.rawValue
        } else if format == .encv, let protectedType = protection.lazy.compactMap(\.protectedVideoCodecType).first {
            // Protected video is named by its original format and scheme, as decoders of protected media know it.
            codecType = protectedType.rawValue
        }

        guard var values = try? extensions.build() else {
            return nil
        }
        let codec = MP4Box.BoxType(rawValue: codecType)
        if let codec, let flavor = VideoSampleEntryUtil.ParameterSetFlavor(codecType: codec) {
            guard VideoSampleEntryUtil.addFallbackExtensions(to: &values, flavor: flavor, extensions: extensions) else {
                return nil
            }
        }
        if let codec, ProResUtil.formats.contains(codec) {
            VideoSampleEntryUtil.addProResExtensions(to: &values, codecType: codec, depth: header.depth)
        }
        if codec == .s263, !extensions.unknownBoxPayloads(of: .d263).isEmpty {
            codecType = MP4Box.BoxType.h263.rawValue
        } else if codec == .mjpg, !isQuickTime {
            codecType = MP4Box.BoxType.jpeg.rawValue
        } else if let codec, let twin = VideoSampleEntryUtil.twinWithParameterSetsInConfig(of: codec, extensions: extensions) {
            codecType = twin.rawValue
        }

        guard let formatDescription = try? CMFormatDescription(
            videoCodecType: CMFormatDescription.MediaSubType(rawValue: codecType),
            width: header.width,
            height: header.height,
            extensions: values
        ) else {
            return nil
        }

        return VideoSampleEntryData(
            formatDescription: formatDescription,
            codecType: codecType,
            width: header.width,
            height: header.height
        )
    }

    private func parsePaspFrom(_ parent: inout BlockBufferReader, position: Int) throws -> Float {
        parent.moveReaderIndex(to: position + MP4Box.headerSize)
        let hSpacing = try parent.readInt(as: UInt32.self)
        let vSpacing = try parent.readInt(as: UInt32.self)
        return Float(hSpacing) / Float(vSpacing)
    }

    private func parseHdlr(hdlr: BlockBufferReader) throws -> UInt32 {
        var hdlr = hdlr
        hdlr.moveReaderIndex(to: Int(MP4Box.fullHeaderSize) + 4)
        return try hdlr.readInt(as: UInt32.self)
    }
}

extension BoxParser {
    struct Mp4TimestampData {
        let creationTimestampSeconds: Int64
        let modificationTimestampSeconds: Int64
        let timescale: CMTimeScale

        init(mvhd: BlockBufferReader?) throws {
            guard var mvhd else {
                throw BoxParserErrors.missingBox(type: .mvhd)
            }
            mvhd.moveReaderIndex(to: Int(MP4Box.headerSize))
            let (version, _) = try BoxParser.readFullboxExtra(reader: &mvhd)
            if version == 0 {
                creationTimestampSeconds = try Int64(mvhd.readInt(as: UInt32.self))
                modificationTimestampSeconds = try Int64(mvhd.readInt(as: UInt32.self))
            } else {
                creationTimestampSeconds = try Int64(mvhd.readInt(as: UInt64.self))
                modificationTimestampSeconds = try Int64(mvhd.readInt(as: UInt64.self))
            }
            self.timescale = try CMTimeScale(mvhd.readInt(as: UInt32.self))
        }
    }

    struct TkhdData {
        let trackId: Int
        let durationTimeValue: CMTimeValue?
        let rotationDegrees: CGFloat
        let transform3D: CATransform3D

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
            let tx = try int32()
            let ty = try int32()
            let w = try int32() // usually 1<<30 (i.e. 1.0)

            let aF = fx16(a)
            let bF = fx16(b)
            let cF = fx16(c)
            let dF = fx16(d)
            let txF = fx16(tx)
            let tyF = fx16(ty)
            _ = fx30(w) // generally 1.0; not used below

            // 4×4 CATransform3D (same as CATransform3DMakeAffineTransform(affine))
            var t = CATransform3DIdentity
            t.m11 = aF
            t.m12 = bF
            t.m21 = cF
            t.m22 = dF
            t.m41 = txF
            t.m42 = tyF
            self.transform3D = t

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

    struct AudioSampleEntryData {
        let formatDescription: CMAudioFormatDescription
        let streamDescription: AudioStreamBasicDescription
        /// The elementary stream descriptor of MPEG-4 audio.
        let elementaryStreamDescriptor: ElementaryStreamDescriptor?
    }

    struct VideoSampleEntryData {
        let formatDescription: CMVideoFormatDescription
        let codecType: CMVideoCodecType
        let width: Int
        let height: Int
    }

    struct StsdData2 {
        static let headerSize = 8
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
