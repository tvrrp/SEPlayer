//
//  Mpeg4AudioUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import Foundation
import SEPlayerCommon

/// Describes MPEG-4 audio: AAC and the other streams an elementary stream descriptor of ISO/IEC 14496-1 announces.
enum Mpeg4AudioUtil {
    /// The objectTypeIndication of MPEG-4 audio.
    static let mpeg4AudioObjectType = 0x40
    /// The streamType of audio.
    static let audioStreamType = 5

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

extension Format where Scope == FormatAttributes.Audio {
    /// The format of MPEG-4 audio outside any sample entry, as for ADTS or LATM, with the `mp4a` sample entry and
    /// the `esds` box an ISO file would describe it by.
    init(audioSpecificConfig: some Collection<UInt8>) throws {
        let config = try BlockBufferReader(bytes: audioSpecificConfig)
        let descriptor = ElementaryStreamDescriptor.bytes(
            objectTypeIndication: Mpeg4AudioUtil.mpeg4AudioObjectType,
            streamType: Mpeg4AudioUtil.audioStreamType,
            decoderSpecificInfo: audioSpecificConfig
        )
        // The box: its version and flags, then the descriptor.
        let esds = [0, 0, 0, 0] + descriptor

        self.init()
        try setAudioSpecificConfig(config)
        self.codecs = try ElementaryStreamDescriptor(esds: BlockBufferReader(bytes: descriptor), readsClockReference: false)?.codecs
        self.boxes = [MediaBox(type: "esds", payload: Data(esds))]
        self.sampleEntry = SampleEntry(
            bytes: Data(Self.sampleEntry(
                type: .mp4a,
                channelCount: self.channelCount ?? 0,
                sampleRate: self.codec?.aac.coreSampleRate ?? 0,
                boxes: BlockBufferReader.box(type: .esds, payload: esds)
            )),
            isQuickTime: false
        )
    }

    /// Sets the codec of an AudioSpecificConfig, with the rate of its output and its channels.
    mutating func setAudioSpecificConfig(_ config: BlockBufferReader) throws {
        let aac = try CodecAttributes<AudioCodec.AAC>(audioSpecificConfig: config)
        self.codec = AudioCodec.aac { $0 = aac }
        // The rate of the output: twice that of the core with spectral band replication.
        self.sampleRate = aac.extensionSampleRate ?? aac.coreSampleRate
        self.channelCount = try AudioSpecificConfig(reader: config).channelCount ?? self.channelCount
    }

    /// An `AudioSampleEntry` of ISO/IEC 14496-12, 12.2.3, of version 0, with `boxes` after its fields.
    private static func sampleEntry(
        type: MP4Box.BoxType,
        channelCount: Int,
        sampleRate: Int,
        boxes: [UInt8]
    ) -> [UInt8] {
        let fields: [UInt8] = [0, 0, 0, 0, 0, 0] // reserved
            + UInt16(1).bigEndianBytes // data_reference_index
            + [UInt8](repeating: 0, count: 8) // reserved
            + UInt16(clamping: channelCount).bigEndianBytes
            + UInt16(16).bigEndianBytes // samplesize
            + [0, 0, 0, 0] // pre_defined, reserved
            // A rate of 16.16 fixed point: one that doesn't fit is left to the codec's configuration.
            + UInt32(sampleRate <= UInt16.max ? sampleRate << 16 : 0).bigEndianBytes
        return BlockBufferReader.box(type: type, payload: fields + boxes)
    }
}

extension ElementaryStreamDescriptor {
    /// The codec string of RFC 6381, such as `mp4a.40.2`.
    var codecs: String {
        let objectType = String(format: "mp4a.%02X", objectTypeIndication)
        return audioObjectType.map { "\(objectType).\($0)" } ?? objectType
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
        // The AudioSpecificConfig of AAC LC, stereo at 44.1 kHz.
        _ = try? AudioFormat(audioSpecificConfig: [0x12, 0x10]).formatDescription()
    }
}
