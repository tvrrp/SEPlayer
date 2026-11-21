//
//  AudioFormat+CoreMedia.swift
//  SEPlayer
//

import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

public extension Format where Scope == FormatAttributes.Audio {
    /// A format description of the samples.
    ///
    /// The system reads the sample entry of the format, as it reads the one of a file. A format without an entry,
    /// or with one the system doesn't read, is described by its codec, its rate and its channels, which the codec's
    /// decoder completes: enough for streams whose frames describe themselves, such as MPEG audio or AC-3.
    func formatDescription() throws -> CMFormatDescription {
        if let entry = self.sampleEntry, let description = try? Self.systemDescription(of: entry) {
            return description
        }

        let codec = try self.codec.checkNotNil(FormatConversionError.missingAttribute("codec"))
        var description = try Self.streamDescription(
            codec: codec,
            sampleRate: self.sampleRate ?? 0,
            channelCount: self.channelCount ?? 0
        )
        let magicCookie = try Self.magicCookie(codec: codec, boxes: self.boxes)
        if let completed = try? AudioFormatProperties.formatInfo(description: description, magicCookie: magicCookie) {
            description = completed
        }
        return try CMFormatDescription(
            audioStreamBasicDescription: description,
            layout: self.channelLayout?.audioChannelLayout,
            magicCookie: magicCookie,
            extensions: nil
        )
    }
}

private extension Format where Scope == FormatAttributes.Audio {
    static func systemDescription(of entry: SampleEntry) throws -> CMFormatDescription {
        let blockBuffer = try BlockBufferReader(bytes: entry.bytes).blockBuffer
        return try CMFormatDescription(
            bigEndianSoundDescription: blockBuffer,
            flavor: entry.isQuickTime ? .quickTimeMovieV2 : .isoFamily
        )
    }

    /// The description of the stream of a codec, before its decoder completes it.
    static func streamDescription(codec: AudioCodec, sampleRate: Int, channelCount: Int) throws -> AudioStreamBasicDescription {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = Float64(sampleRate)
        description.mChannelsPerFrame = UInt32(clamping: channelCount)
        if codec.mimeType == .audioRAW {
            let pcm = codec.pcm
            let bitDepth = pcm.bitDepth ?? 16
            description.mFormatID = kAudioFormatLinearPCM
            description.mFormatFlags = kAudioFormatFlagIsPacked | (pcm.isBigEndian ? kAudioFormatFlagIsBigEndian : 0)
            switch pcm.sampleFormat {
            case .float: description.mFormatFlags |= kAudioFormatFlagIsFloat
            case .signedInteger: description.mFormatFlags |= kAudioFormatFlagIsSignedInteger
            case .unsignedInteger: break
            }
            description.mBitsPerChannel = UInt32(bitDepth)
            description.mBytesPerFrame = UInt32(bitDepth / 8 * channelCount)
            description.mBytesPerPacket = description.mBytesPerFrame
            description.mFramesPerPacket = 1
            return description
        }
        description.mFormatID = try formatIDs[codec.mimeType].checkNotNil(FormatConversionError.unsupportedCodec(codec.mimeType))
        return description
    }

    /// What the decoder of a codec needs besides the stream description, from the configuration box of the codec.
    static func magicCookie(codec: AudioCodec, boxes: [MediaBox]) throws -> BlockBufferReader? {
        guard codec.mimeType == .audioAAC, let esds = boxes.payload(of: "esds"), esds.count > 4 else { return nil }
        // The `ES_Descriptor`, after the version and flags of the box.
        return try BlockBufferReader(bytes: esds.dropFirst(4))
    }

    /// The formats audio services know the codecs by.
    static var formatIDs: [MimeTypes: AudioFormatID] {
        [
            .audioAAC: kAudioFormatMPEG4AAC,
            .audioMPEG: kAudioFormatMPEGLayer3,
            .audioMPEGL2: kAudioFormatMPEGLayer2,
            .audioMPEGL1: kAudioFormatMPEGLayer1,
            .audioAC3: kAudioFormatAC3,
            .audioEAC3: kAudioFormatEnhancedAC3,
            .audioEAC3JOC: kAudioFormatEnhancedAC3,
            .audioAC4: FourCharacterCode("ac-4").rawValue,
            .audioTRUEHD: FourCharacterCode("mlpa").rawValue,
            .audioDTS: FourCharacterCode("dtsc").rawValue,
            .audioDTSHD: FourCharacterCode("dtsh").rawValue,
            .audioDTSExpress: FourCharacterCode("dtse").rawValue,
            .audioDTSX: FourCharacterCode("dtsx").rawValue,
            .audioMPEGHMHA1: FourCharacterCode("mha1").rawValue,
            .audioMPEGHMHM1: FourCharacterCode("mhm1").rawValue,
            .audioOPUS: kAudioFormatOpus,
            .audioFLAC: kAudioFormatFLAC,
            .audioALAC: kAudioFormatAppleLossless,
            .audioAMRNB: kAudioFormatAMR,
            .audioAMRWB: kAudioFormatAMR_WB,
            .audioALAW: kAudioFormatALaw,
            .audioMLAW: kAudioFormatULaw,
            .audioMSGSM: kAudioFormatMicrosoftGSM,
            .audioAPAC: FourCharacterCode("apac").rawValue,
            .audioIAMF: FourCharacterCode("iamf").rawValue,
        ]
    }
}
