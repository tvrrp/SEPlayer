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
    /// The format services read the descriptor. Their AAC is of an audio object type its format names, as HE-AAC; the
    /// description is then the plainest format of the stream, the one every decoder of it plays.
    ///
    /// - Parameters:
    ///   - esds: The payload of the `esds` box after its version and flags.
    ///   - sampleEntryDescription: The description of the fields of the sample entry, for streams the format services
    ///     don't read.
    /// - Returns: `nil` for a stream whose descriptor holds no cookie although its format needs one.
    static func streamDescription(
        esds: BlockBufferReader,
        descriptor: ElementaryStreamDescriptor?,
        sampleEntryDescription: AudioStreamBasicDescription
    ) -> (AudioStreamBasicDescription, BlockBufferReader?)? {
        if descriptor?.isMpegAudio == true {
            // MPEG audio needs no cookie: the decoder reads each frame's header.
            var description = sampleEntryDescription
            description.mFormatID = kAudioFormatMPEGLayer3
            description.mFramesPerPacket = 1152
            return (description, nil)
        }

        var description: AudioStreamBasicDescription
        let cookie: BlockBufferReader
        if let (info, descriptorCookie) = try? AudioFormatProperties.formatInfo(esds: esds) {
            guard let descriptorCookie else { return nil }
            description = info
            cookie = descriptorCookie
        } else if let info = try? AudioFormatProperties.mpeg4StreamDescription(esds: esds) {
            description = info
            cookie = esds
        } else {
            return nil
        }

        // The format services give AAC the audio object type as its flags.
        if description.mFormatID == kAudioFormatMPEG4AAC, let format = aacFormat(audioObjectType: description.mFormatFlags) {
            var typed = description
            typed.mFormatID = format
            if let list = try? AudioFormatProperties.formatList(description: typed, magicCookie: esds), let plainest = list.last {
                description = plainest.mASBD
            }
        }
        return (description, cookie)
    }

    /// The format description of an MPEG-4 audio stream from its elementary stream descriptor alone, as for a
    /// stream outside any sample entry.
    static func formatDescription(esds: BlockBufferReader) throws -> CMAudioFormatDescription {
        let descriptor = ElementaryStreamDescriptor(esds: esds)
        guard let (description, cookie) = streamDescription(
            esds: esds,
            descriptor: descriptor,
            sampleEntryDescription: AudioStreamBasicDescription()
        ) else {
            throw AudioFormatError.noFormats
        }
        return try AudioSampleEntryUtil.makeFormatDescription(
            description: description,
            magicCookie: cookie,
            explicitLayout: nil,
            fallbackLayout: { (try? AudioFormatProperties.mpeg4ChannelLayout(esds: esds)).map { ManagedAudioChannelLayout(tag: $0.tag) } },
            extensions: nil
        ).0
    }

    /// The format of AAC of an audio object type that has one besides AAC.
    private static func aacFormat(audioObjectType: AudioFormatFlags) -> AudioFormatID? {
        switch audioObjectType {
        case 5: kAudioFormatMPEG4AAC_HE
        case 23: kAudioFormatMPEG4AAC_LD
        case 29: kAudioFormatMPEG4AAC_HE_V2
        case 30: kAudioFormatMPEG4AAC_Spatial
        default: nil
        }
    }

    /// Whether an entry of `format` is AAC that QuickTime describes with an `esds` box: `aac ` and its profiles.
    static func isAACWithElementaryStreamDescriptor(_ rawFormat: UInt32) -> Bool {
        if let format = MP4Box.BoxType(rawValue: rawFormat), [.aac_, .aach, .aacl, .aacp, .aacs].contains(format) {
            return true
        }
        let aacPrefix = MP4Box.BoxType.aac_.rawValue >> 8
        // `aace` to `aacg` are other codecs.
        return rawFormat >> 8 == aacPrefix && !(0x65...0x67).contains(rawFormat & 0xFF)
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
        case 0x40, 0x66, 0x67, 0x68: .audioAAC
        case 0x69, 0x6B: .audioMPEG
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
