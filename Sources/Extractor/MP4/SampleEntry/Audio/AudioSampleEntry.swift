//
//  AudioSampleEntry.swift
//  SEPlayer
//

import Foundation
import SEPlayerCommon

/// Reads audio sample entries into formats: the codec with its configuration, the rate and the channels, and the
/// entry with its boxes, of which each platform makes its decoder's format.
enum AudioSampleEntry {
    /// - Parameters:
    ///   - entry: The whole sample entry, from its size field, its indices starting at 0.
    ///   - isQuickTime: Whether the file is a QuickTime movie rather than an ISO file.
    /// - Returns: The format and the elementary stream descriptor of MPEG-4 audio, or `nil` for an entry of a codec
    ///   not known here, or one that can't be read.
    static func format(
        entry: BlockBufferReader,
        isQuickTime: Bool
    ) -> (format: AudioFormat, descriptor: ElementaryStreamDescriptor?)? {
        guard let sound = SoundDescription(entry: entry, isQuickTime: isQuickTime),
              let boxes = sound.readBoxes(isQuickTime: isQuickTime) else {
            return nil
        }

        var format = AudioFormat()
        if let version2 = sound.version2 {
            format.sampleRate = Int(version2.sampleRate)
            format.channelCount = Int(version2.channelCount)
        } else {
            format.sampleRate = boxes.sampleRate.map { Int($0) } ?? Int(sound.sampleRate(isQuickTime: isQuickTime))
            format.channelCount = sound.channelCount
        }

        let descriptor = boxes.esds
            .flatMap { try? $0.payload.slice(from: 4) }
            .flatMap { ElementaryStreamDescriptor(esds: $0, readsClockReference: false) }
        do {
            try readCodec(of: mediaType(sound: sound, boxes: boxes), sound: sound, boxes: boxes, descriptor: descriptor, into: &format)
            try format.setSampleEntry(entry, isQuickTime: isQuickTime)
            try format.keepBoxes(boxes.all)
            try boxes.sinf.map { ProtectionScheme(sinf: $0.payload) }?.apply(to: &format)
        } catch {
            return nil
        }
        return (format, descriptor)
    }

    /// The type of the media: that of the entry, or for protected media and types named by their configuration
    /// alone, the type of the configuration box.
    private static func mediaType(sound: SoundDescription, boxes: SoundDescription.Boxes) -> UInt32 {
        let configuredType: MP4Box.BoxType? = if boxes.dac3 != nil {
            .ac_3
        } else if boxes.dec3 != nil {
            .ec_3
        } else if boxes.dfLa != nil {
            .fLaC
        } else if boxes.alac != nil {
            .alac
        } else if boxes.esds != nil {
            .mp4a
        } else {
            boxes.all.lazy.compactMap { $0.type.flatMap { registeredTypes[$0] } }.first
        }
        if sound.format == .enca {
            return configuredType?.rawValue ?? sound.rawFormat
        }
        return isKnown(sound.rawFormat) ? sound.rawFormat : configuredType?.rawValue ?? sound.rawFormat
    }

    private static func readCodec(
        of rawType: UInt32,
        sound: SoundDescription,
        boxes: SoundDescription.Boxes,
        descriptor: ElementaryStreamDescriptor?,
        into format: inout AudioFormat
    ) throws {
        let type = MP4Box.BoxType(rawValue: rawType)
        if PcmUtil.quickTimeFormats.contains(rawType) {
            let attributes = sound.version2.map(PcmUtil.attributes(version2:)) ?? PcmUtil.attributes(
                format: rawType,
                sampleSize: sound.sampleSize,
                isLittleEndian: boxes.isLittleEndian
            )
            format.codec = .pcm { $0 = attributes }
            return
        }
        if type == .mp4a || type == .m4ae || Mpeg4AudioUtil.isAACWithElementaryStreamDescriptor(rawType) {
            if descriptor?.isMpegAudio == true {
                format.codec = AudioCodec(.audioMPEG)
            } else if let config = descriptor?.decoderSpecificInfo {
                try format.setAudioSpecificConfig(config)
            } else {
                format.codec = AudioCodec(.audioAAC)
            }
            return
        }

        switch type {
        case .ac_3?:
            let ac3 = try boxes.dac3.map { try CodecAttributes<AudioCodec.AC3>(dac3: $0.payload) }
            format.codec = .ac3 { $0 = ac3 ?? $0 }
            format.sampleRate = ac3?.sampleRate ?? format.sampleRate
            format.channelCount = ac3?.channelCount ?? format.channelCount
        case .ec_3?:
            let eac3 = try CodecAttributes<AudioCodec.EAC3>(dec3: boxes.dec3.checkNotNil().payload)
            format.codec = .eac3 { $0 = eac3 }
            format.sampleRate = eac3.sampleRate ?? format.sampleRate
            format.channelCount = eac3.channelCount ?? format.channelCount
        case .alac?:
            let alac = try boxes.alac.map { try CodecAttributes<AudioCodec.ALAC>(alac: $0.box) }
            format.codec = .alac { $0 = alac ?? $0 }
            format.sampleRate = alac?.sampleRate ?? format.sampleRate
            format.channelCount = alac?.channelCount ?? format.channelCount
        case .fLaC?,
             .flac?:
            let flac = try boxes.dfLa.map { try CodecAttributes<AudioCodec.FLAC>(dfLa: $0.box) }
            format.codec = .flac { $0 = flac ?? $0 }
            format.sampleRate = flac?.sampleRate ?? format.sampleRate
            format.channelCount = flac?.channelCount ?? format.channelCount
        case .Opus?:
            let opus = try CodecAttributes<AudioCodec.Opus>(dOps: boxes.dOps.checkNotNil().payload)
            format.codec = .opus { $0 = opus }
            // Opus decodes at 48000 Hz, whatever the rate of its input was.
            format.sampleRate = 48000
            format.channelCount = opus.channelCount ?? format.channelCount
        case .samr?,
             .sawb?:
            var codec = AudioCodec(type == .samr ? .audioAMRNB : .audioAMRWB)
            if let config = boxes.amrConfig {
                codec.amr = try CodecAttributes(damr: config)
            }
            format.codec = codec
            format.sampleRate = type == .samr ? 8000 : 16000
            format.channelCount = 1
        case .ipcm?,
             .fpcm?:
            let attributes = try boxes.pcmC.flatMap { PcmUtil.attributes(pcmC: $0.payload, isFloat: type == .fpcm) }.checkNotNil()
            format.codec = .pcm { $0 = attributes }
        default:
            format.codec = try otherCodec(of: type, boxes: boxes).checkNotNil()
        }
    }

    /// The codecs whose stream needs no configuration read here, and those whose decoder takes their box as it is.
    private static func otherCodec(of type: MP4Box.BoxType?, boxes: SoundDescription.Boxes) throws -> AudioCodec? {
        func box(_ type: MP4Box.BoxType) -> SampleEntryBox? {
            boxes.all.first { $0.type == type }
        }
        func whole(_ type: MP4Box.BoxType) throws -> Data? {
            try box(type)?.box.readableData()
        }

        switch type {
        case ._mp3?:
            return AudioCodec(.audioMPEG)
        case .ulaw?:
            return AudioCodec(.audioMLAW)
        case .alaw?:
            return AudioCodec(.audioALAW)
        case .apac?:
            var codec = AudioCodec(.audioAPAC)
            if let dapa = box(.dapa) {
                codec.apac = try CodecAttributes(dapa: dapa.box)
            }
            return codec
        case .ac_4?:
            return try AudioCodec(.audioAC4, \.ac4) { $0.decoderSpecificInfo = try whole(.dac4) }
        case .mlpa?:
            var codec = AudioCodec(.audioTRUEHD)
            if var dmlp = box(.dmlp)?.payload {
                codec.trueHD.formatInfo = try dmlp.readInt(as: UInt32.self)
                codec.trueHD.peakDataRate = try Int(dmlp.readInt(as: UInt16.self) >> 1)
            }
            return codec
        case .iamf?:
            return try AudioCodec(.audioIAMF, \.iamf) { $0.decoderSpecificInfo = try whole(.iacb) }
        case .mha1?,
             .mhm1?:
            var codec = AudioCodec(type == .mha1 ? .audioMPEGHMHA1 : .audioMPEGHMHM1)
            if let mhaC = box(.mhaC)?.payload {
                codec.mpegH = try CodecAttributes(mhaC: mhaC)
            }
            return codec
        case .dtsc?:
            return AudioCodec(.audioDTS)
        case .dtsh?,
             .dtsl?:
            return AudioCodec(.audioDTSHD)
        case .dtse?:
            return AudioCodec(.audioDTSExpress)
        case .dtsx?:
            return AudioCodec(.audioDTSX)
        default:
            return nil
        }
    }

    /// Whether the type of an entry names a codec known here.
    static func isKnown(_ rawType: UInt32) -> Bool {
        MP4Box.BoxType(rawValue: rawType).map(knownTypes.contains) == true
            || PcmUtil.quickTimeFormats.contains(rawType)
            || Mpeg4AudioUtil.isAACWithElementaryStreamDescriptor(rawType)
    }

    private static let knownTypes: Set<MP4Box.BoxType> = [
        .mp4a, .m4ae, .ac_3, .ec_3, .alac, .fLaC, .flac, .Opus, .samr, .sawb, .ipcm, .fpcm, .ulaw, .alaw, ._mp3,
        .apac, .ac_4, .mlpa, .iamf, .mha1, .mhm1, .dtsc, .dtsh, .dtsl, .dtse, .dtsx, .enca,
    ]

    /// The types of the media of the configuration boxes that alone tell it: APAC, AC-4, Dolby TrueHD and IAMF.
    private static let registeredTypes: [MP4Box.BoxType: MP4Box.BoxType] = [
        .dapa: .apac, .dac4: .ac_4, .dmlp: .mlpa, .iacb: .iamf,
    ]
}
