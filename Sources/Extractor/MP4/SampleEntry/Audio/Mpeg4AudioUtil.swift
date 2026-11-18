//
//  Mpeg4AudioUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import CoreAudio
import CoreMedia
import SEPlayerCommon

/// Describes MPEG-4 audio: AAC and the other streams an elementary stream descriptor of ISO/IEC 14496-1 announces.
enum Mpeg4AudioUtil {
    /// The stream description and the magic cookie of an MPEG-4 audio stream.
    ///
    /// AAC is described as its core coder at the core rate, the plainest format of the stream that every decoder of
    /// it plays: HE-AAC as AAC at half the rate. The decoder takes the whole descriptor as its cookie.
    ///
    /// - Parameters:
    ///   - esds: The payload of the `esds` box after its version and flags.
    ///   - sampleEntryDescription: The description of the fields of the sample entry, for MPEG audio, which the
    ///     descriptor doesn't describe.
    /// - Returns: `nil` for a stream whose config can't be read, or which the system can't decode.
    static func streamDescription(
        esds: BlockBufferReader,
        descriptor: ElementaryStreamDescriptor?,
        sampleEntryDescription: AudioStreamBasicDescription
    ) -> (AudioStreamBasicDescription, BlockBufferReader?)? {
        guard let descriptor else { return nil }
        if descriptor.isMpegAudio {
            // MPEG audio needs no cookie: the decoder reads each frame's header.
            var description = sampleEntryDescription
            description.mFormatID = kAudioFormatMPEGLayer3
            description.mFramesPerPacket = 1152
            return (description, nil)
        }
        guard let description = audioSpecificConfig(descriptor: descriptor)?.streamDescription else {
            return nil
        }
        return (description, esds)
    }

    /// The layout of the channels of an MPEG-4 audio stream, as its config names them.
    static func channelLayout(descriptor: ElementaryStreamDescriptor) -> ManagedAudioChannelLayout? {
        audioSpecificConfig(descriptor: descriptor)?.channelLayoutTag.map(ManagedAudioChannelLayout.init(tag:))
    }

    /// The format description of an MPEG-4 audio stream from its elementary stream descriptor alone, as for a
    /// stream outside any sample entry.
    static func formatDescription(esds: BlockBufferReader) throws -> CMAudioFormatDescription {
        guard let descriptor = ElementaryStreamDescriptor(esds: esds, readsClockReference: false),
              let (description, cookie) = streamDescription(
                  esds: esds,
                  descriptor: descriptor,
                  sampleEntryDescription: AudioStreamBasicDescription()
              ) else {
            throw AudioConfigError()
        }
        return try AudioSampleEntryUtil.makeFormatDescription(
            description: description,
            magicCookie: cookie,
            explicitLayout: nil,
            fallbackLayout: { channelLayout(descriptor: descriptor) },
            extensions: nil
        ).0
    }

    /// The AudioSpecificConfig of an MPEG-4 audio stream.
    ///
    /// - Returns: `nil` for another kind of stream, or a config that can't be read.
    private static func audioSpecificConfig(descriptor: ElementaryStreamDescriptor) -> AudioSpecificConfig? {
        guard descriptor.objectTypeIndication == mpeg4AudioObjectType, descriptor.streamType == audioStreamType,
              let info = descriptor.decoderSpecificInfo else {
            return nil
        }
        return try? AudioSpecificConfig(reader: info)
    }

    /// Whether an entry of `format` is AAC that QuickTime describes with an `esds` box: `aac ` and its profiles.
    static func isAACWithElementaryStreamDescriptor(_ rawFormat: UInt32) -> Bool {
        if let format = MP4Box.BoxType(rawValue: rawFormat), [.aac_, .aach, .aacl, .aacp, .aacs].contains(format) {
            return true
        }
        let aacPrefix = MP4Box.BoxType.aac_.rawValue >> 8
        // `aace` to `aacg` are other codecs.
        return rawFormat >> 8 == aacPrefix && !(0x65 ... 0x67).contains(rawFormat & 0xFF)
    }
}

extension ElementaryStreamDescriptor {
    /// The codec string of RFC 6381, such as `mp4a.40.2`.
    var codecs: String {
        let objectType = String(format: "mp4a.%02X", objectTypeIndication)
        return audioObjectType.map { "\(objectType).\($0)" } ?? objectType
    }

    var audioMimeType: MimeTypes? {
        switch objectTypeIndication {
        case 0x40,
             0x66,
             0x67,
             0x68: .audioAAC
        case 0x69,
             0x6B: .audioMPEG
        case 0xA5: .audioAC3
        case 0xA6: .audioEAC3
        case 0xAD: .audioOPUS
        default: nil
        }
    }

    /// Whether the stream is MPEG-1 or MPEG-2 audio, layer III or lower.
    var isMpegAudio: Bool {
        objectTypeIndication == 0x69 || objectTypeIndication == 0x6B
    }
}

/// Loads what the format services read sample entries with, ahead of the first one.
public enum AudioFormatServices {
    /// The first question to the format services loads their registry of codecs, and the first one about a codec
    /// opens it: a few milliseconds each, on the way to the first frame unless they are asked before.
    public static func prewarm() {
        // An elementary stream descriptor of AAC LC, stereo at 44.1 kHz.
        let esds: [UInt8] = [
            0x03, 0x19, 0x00, 0x01, 0x00, 0x04, 0x11, 0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4, 0x00,
            0x00, 0x01, 0xF4, 0x00, 0x05, 0x02, 0x12, 0x10, 0x06, 0x01, 0x02,
        ]
        guard let reader = try? BlockBufferReader(bytes: esds) else { return }
        _ = try? Mpeg4AudioUtil.formatDescription(esds: reader)
    }
}

private extension Mpeg4AudioUtil {
    /// The objectTypeIndication of MPEG-4 audio.
    static let mpeg4AudioObjectType = 0x40
    /// The streamType of audio.
    static let audioStreamType = 5
}
