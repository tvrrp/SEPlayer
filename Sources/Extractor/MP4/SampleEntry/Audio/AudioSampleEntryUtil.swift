//
//  AudioSampleEntryUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import CoreAudio
import CoreMedia
import SEPlayerCommon

/// Helpers for reading audio sample entries into format descriptions.
enum AudioSampleEntryUtil {
    /// The formats of sample entries read here, besides QuickTime's linear PCM and AAC.
    static let formats: Set<MP4Box.BoxType> = [
        .mp4a, .m4ae, .ac_3, .ec_3, .alac, .fLaC, .flac, .Opus, .samr, .sawb, .ipcm, .fpcm,
        .ulaw, .alaw, ._mp3, .ima4, .MAC3, .MAC6, .enca,
    ]

    /// Whether an entry of `format` is read here.
    static func reads(_ rawFormat: UInt32) -> Bool {
        MP4Box.BoxType(rawValue: rawFormat).map(formats.contains) == true
            || PcmUtil.quickTimeFormats.contains(rawFormat)
            || Mpeg4AudioUtil.isAACWithElementaryStreamDescriptor(rawFormat)
    }

    /// A codec the format services know by the box of its decoder config, rather than by code here.
    struct RegisteredCodec {
        /// The format that decodes the config.
        let format: AudioFormatID
        /// The config as the decoder takes it.
        let magicCookie: BlockBufferReader
        /// Where the config box is among the boxes no extension describes; it isn't kept as they are.
        let configBoxIndex: Int

        /// The first of `boxes` whose type the format services know: the config box of the entry's format, or a box
        /// of a single format.
        init?(entryFormat: UInt32, boxes: [SampleEntryBox], isQuickTime: Bool) {
            let flavor: AudioFormatProperties.ContainerFlavor = isQuickTime ? .quickTimeMovie : .isoFamily
            let entryConfigType = AudioFormatProperties.configBoxType(codingName: entryFormat, flavor: flavor)
            for (index, box) in boxes.enumerated() {
                let format = box.rawType == entryConfigType
                    ? AudioFormatProperties.decodeFormat(codingName: entryFormat, flavor: flavor)
                    : AudioFormatProperties.decodeFormat(configBoxType: box.rawType, flavor: flavor)
                guard let format else {
                    continue
                }
                guard let cookie = try? AudioFormatProperties.canonicalMagicCookie(configBox: box.box, format: format, flavor: flavor) else {
                    return nil
                }
                self.format = format
                magicCookie = cookie
                configBoxIndex = index
                return
            }
            return nil
        }
    }

    /// The cookie of protected media: its config box as it is, and for AAC its descriptor in an `esds` box.
    ///
    /// - Returns: `nil` for a descriptor that can't be read; a `Cookie` without a reader for a codec known by its
    ///   registered config instead.
    static func protectedMagicCookie(boxes: SoundDescription.Boxes, esds: BlockBufferReader?) -> Cookie? {
        if let config = boxes.dac3 ?? boxes.dec3 ?? boxes.dfLa ?? boxes.alac {
            return Cookie(reader: config.box)
        }
        if let esds {
            guard let bytes = try? esds.getBytes(at: esds.readerIndex, length: esds.readableBytes),
                  let box = try? BlockBufferReader(bytes: BlockBufferReader.box(type: .esds, payload: bytes)) else {
                return nil
            }
            return Cookie(reader: box)
        }
        return Cookie()
    }

    /// The codec of protected media, by the config box it carries.
    static func protectedCodec(boxes: SoundDescription.Boxes) -> MP4Box.BoxType? {
        if boxes.dac3 != nil { return .ac_3 }
        if boxes.dec3 != nil { return .ec_3 }
        if boxes.dfLa != nil { return .fLaC }
        if boxes.alac != nil { return .alac }
        if boxes.esds != nil { return .mp4a }
        return nil
    }

    // MARK: - Fields

    /// The stream description of the entry's fields, before its codec config is read.
    ///
    /// - Parameter format: The format of the media, the original one of protected media.
    static func sampleEntryDescription(
        sound: SoundDescription,
        format: UInt32,
        boxes: SoundDescription.Boxes,
        isQuickTime: Bool
    ) -> AudioStreamBasicDescription? {
        var description: AudioStreamBasicDescription
        if let version2 = sound.version2 {
            let isLinearPCM = format == MP4Box.BoxType.lpcm.rawValue
            // QuickTime version 2 names linear PCM by `lpcm` alone.
            guard isLinearPCM || !PcmUtil.quickTimeFormats.contains(format) else {
                return nil
            }
            description = AudioStreamBasicDescription(
                mSampleRate: version2.sampleRate,
                mFormatID: format,
                mFormatFlags: isLinearPCM ? PcmUtil.version2Flags(version2.formatFlags) : version2.formatFlags,
                mBytesPerPacket: version2.bytesPerPacket,
                mFramesPerPacket: version2.framesPerPacket,
                mBytesPerFrame: isLinearPCM ? version2.bytesPerPacket : 0,
                mChannelsPerFrame: version2.channelCount,
                mBitsPerChannel: version2.bitsPerChannel,
                mReserved: 0
            )
            return description
        }

        let sampleRate = sound.sampleRate(isQuickTime: isQuickTime)
        if PcmUtil.quickTimeFormats.contains(format) {
            description = PcmUtil.streamDescription(
                format: format,
                sampleRate: sampleRate,
                channelCount: sound.channelCount,
                sampleSize: sound.sampleSize,
                isLittleEndian: boxes.isLittleEndian
            )
        } else {
            description = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: format,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 0,
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(sound.channelCount),
                mBitsPerChannel: 0,
                mReserved: 0
            )
            // The packet fields of compressed formats; a variable compression has no constant packet size.
            if let version1 = sound.version1, version1.samplesPerPacket != 0 {
                description.mFramesPerPacket = version1.samplesPerPacket
                if sound.compressionID != -2 {
                    description.mBytesPerPacket = version1.bytesPerFrame
                }
            }
        }
        if let sampleRate = boxes.sampleRate {
            description.mSampleRate = Double(sampleRate)
        }
        return description
    }

    // MARK: - Magic cookie

    /// What the decoder needs besides the stream description, wrapped so that "none" differs from "unreadable".
    struct Cookie {
        var reader: BlockBufferReader?
    }

    /// The codec config the decoder needs: as ISO files carry it, the config box itself or a cookie made from it;
    /// QuickTime's `wave` box holds the codec's boxes as they are, except AAC's descriptor.
    ///
    /// - Returns: `nil` when the format's config is missing.
    static func magicCookie(
        format rawFormat: UInt32,
        boxes: SoundDescription.Boxes,
        esds: BlockBufferReader?,
        opusHead: BlockBufferReader?,
        isQuickTime: Bool
    ) -> Cookie? {
        let format = MP4Box.BoxType(rawValue: rawFormat)
        if let format, [.in24, .in32, .fl32, .fl64].contains(format) {
            return Cookie()
        }
        if isQuickTime {
            if format == .mp4a || format == .m4ae || Mpeg4AudioUtil.isAACWithElementaryStreamDescriptor(rawFormat) {
                return Cookie(reader: esds)
            }
            return Cookie(reader: opusHead ?? boxes.wave)
        }
        switch format {
        case .ac_3?:
            return Cookie(reader: boxes.dac3?.box)
        case .ec_3?:
            guard let dec3 = boxes.dec3 else {
                return nil
            }
            return Cookie(reader: dec3.box)
        case .fLaC?:
            guard let dfLa = boxes.dfLa else {
                return nil
            }
            return Cookie(reader: FlacUtil.magicCookie(dfLa: dfLa.box))
        case .ipcm?, .fpcm?:
            guard boxes.pcmC != nil else {
                return nil
            }
            return Cookie()
        case .alac?:
            guard let alac = boxes.alac, let cookie = AlacUtil.magicCookie(alac: alac.box) else {
                return nil
            }
            return Cookie(reader: cookie)
        case .samr?, .sawb?:
            guard let format, let config = boxes.amrConfig,
                  let cookie = AmrUtil.magicCookie(format: format, config: config) else {
                return nil
            }
            return Cookie(reader: cookie)
        default:
            return Cookie(reader: opusHead ?? esds)
        }
    }

    // MARK: - Channel layout

    struct ExplicitLayout {
        var layout: ManagedAudioChannelLayout?
    }

    /// The layout the entry names: a QuickTime `chan` box, or an ISO `chnl` box of linear PCM.
    ///
    /// - Returns: `nil` for a `chan` box that can't be read, or a `chnl` box of more than two channels the format
    ///   services can't read.
    static func explicitLayout(boxes: SoundDescription.Boxes, description: AudioStreamBasicDescription) -> ExplicitLayout? {
        if let chan = boxes.chan {
            // The layout follows the version and flags.
            guard let layoutBytes = try? chan.payload.slice(from: 4),
                  let layout = ManagedAudioChannelLayout(bigEndianLayoutBytes: BlockBufferView(layoutBytes)) else {
                return nil
            }
            return ExplicitLayout(layout: layout)
        }
        if let chnl = boxes.chnl, description.mFormatID == kAudioFormatLinearPCM {
            if let layout = try? AudioFormatProperties.channelLayout(description: description, channelLayoutBox: chnl.box) {
                return ExplicitLayout(layout: layout)
            }
            guard description.mChannelsPerFrame <= 2 else {
                return nil
            }
        }
        return ExplicitLayout()
    }

    // MARK: - Format description

    /// The format description of a stream, completed by its decoder.
    ///
    /// The decoder lists the formats it decodes the stream to; the plainest of them is the stream's, with the layout
    /// the decoder gives its channels. A layout the entry names wins when it has the channels of a format the
    /// decoder plays. Without the decoder, the codec config tells the layout.
    ///
    /// - Parameters:
    ///   - explicitLayout: The layout the entry names.
    ///   - fallbackLayout: The layout of the codec config, for when the decoder lists no formats.
    static func makeFormatDescription(
        description: AudioStreamBasicDescription,
        magicCookie: BlockBufferReader?,
        explicitLayout: ManagedAudioChannelLayout?,
        fallbackLayout: () -> ManagedAudioChannelLayout?,
        extensions: [CFString: Any]?
    ) throws -> (CMAudioFormatDescription, AudioStreamBasicDescription) {
        let (finalDescription, layout) = try resolveDescription(
            description: description,
            magicCookie: magicCookie,
            explicitLayout: explicitLayout,
            fallbackLayout: fallbackLayout
        )
        let formatDescription = try CMFormatDescription(
            audioStreamBasicDescription: finalDescription,
            layout: layout,
            magicCookie: magicCookie,
            extensions: extensions
        )
        return (formatDescription, finalDescription)
    }

    /// The stream description its decoder completes, and the layout of its channels.
    static func resolveDescription(
        description: AudioStreamBasicDescription,
        magicCookie: BlockBufferReader?,
        explicitLayout: ManagedAudioChannelLayout?,
        fallbackLayout: () -> ManagedAudioChannelLayout?
    ) throws -> (AudioStreamBasicDescription, ManagedAudioChannelLayout?) {
        var finalDescription = description
        var decoderLayout: ManagedAudioChannelLayout?
        let formats = try? AudioFormatProperties.formatList(description: description, magicCookie: magicCookie)
        if let plainest = formats?.last {
            finalDescription = plainest.mASBD
            if plainest.mChannelLayoutTag != 0 {
                decoderLayout = ManagedAudioChannelLayout(tag: plainest.mChannelLayoutTag)
            } else {
                decoderLayout = try? AudioFormatProperties.channelLayout(description: plainest.mASBD, magicCookie: magicCookie)
            }
        } else {
            decoderLayout = fallbackLayout()
        }
        finalDescription = (try? AudioFormatProperties.formatInfo(description: finalDescription, magicCookie: magicCookie))
            ?? finalDescription

        var layout = explicitLayout
        if let decoderLayout, decoderLayout.describedChannelCount != 0 {
            var keepsExplicit = false
            if let explicitLayout, let formats {
                let channelCount = UInt32(explicitLayout.describedChannelCount)
                let playable = (try? AudioFormatProperties.firstPlayableFormat(in: formats)) ?? 0
                keepsExplicit = formats[min(playable, formats.count - 1)].mASBD.mChannelsPerFrame == channelCount
                    || formats[formats.count - 1].mASBD.mChannelsPerFrame == channelCount
            }
            if !keepsExplicit { layout = decoderLayout }
        }
        return (finalDescription, layout)
    }
}
