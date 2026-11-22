//
//  MpegAudioUtil.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.MpegAudioUtil
//  Copyright (C) 2020 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import Foundation
import SEPlayerCommon

/// Reads the headers of MPEG audio frames: MPEG-1, MPEG-2 and MPEG-2.5, layers I, II and III.
enum MpegAudioUtil {
    /// The largest frame, in bytes.
    static let maxFrameSizeBytes = 4096
    /// The highest bitrate, in bytes per second.
    static let maxRateBytesPerSecond = 320 * 1000 / 8

    /// What a frame header says.
    struct Header: Equatable {
        /// 3 for MPEG-1, 2 for MPEG-2, 0 for MPEG-2.5.
        var version = 0
        var mimeType: MimeTypes?
        var frameSize = 0
        var sampleRate = 0
        var channels = 0
        var bitrate = 0
        var samplesPerFrame = 0

        /// Reads `headerData`, the first four bytes of a frame.
        ///
        /// - Returns: Whether they are a valid header.
        mutating func setForHeaderData(_ headerData: Int) -> Bool {
            guard isMagicPresent(headerData) else { return false }
            let version = (headerData >> 19) & 3
            let layer = (headerData >> 17) & 3
            let bitrateIndex = (headerData >> 12) & 15
            let samplingRateIndex = (headerData >> 10) & 3
            // Version 1 is reserved, layer 0 is reserved; "free" bitrates aren't allowed.
            guard version != 1, layer != 0, bitrateIndex != 0, bitrateIndex != 0xF, samplingRateIndex != 3 else {
                return false
            }

            self.version = version
            mimeType = mimeTypeByLayer[3 - layer]
            sampleRate = MpegAudioUtil.sampleRate(version: version, samplingRateIndex: samplingRateIndex)
            let padding = (headerData >> 9) & 1
            samplesPerFrame = frameSizeInSamples(version: version, layer: layer)
            bitrate = MpegAudioUtil.bitrate(version: version, layer: layer, bitrateIndex: bitrateIndex)
            frameSize = MpegAudioUtil.frameSize(
                version: version,
                layer: layer,
                bitrate: bitrate,
                sampleRate: sampleRate,
                padding: padding
            )
            channels = ((headerData >> 6) & 3) == 3 ? 1 : 2
            return true
        }
    }

    /// The size of the frame whose header is `headerData`, or `nil` if it isn't a valid header.
    static func frameSize(headerData: Int) -> Int? {
        var header = Header()
        return header.setForHeaderData(headerData) ? header.frameSize : nil
    }

    /// The number of samples of the frame whose header is `headerData`, or `nil` if it isn't a valid header.
    static func frameSampleCount(headerData: Int) -> Int? {
        var header = Header()
        return header.setForHeaderData(headerData) ? header.samplesPerFrame : nil
    }
}

private extension MpegAudioUtil {
    static let mimeTypeByLayer: [MimeTypes] = [.audioMPEGL1, .audioMPEGL2, .audioMPEG]
    static let samplingRateV1 = [44100, 48000, 32000]
    static let bitrateV1L1 = [
        32000, 64000, 96000, 128000, 160000, 192000, 224000, 256000, 288000, 320000, 352000, 384000, 416000, 448000,
    ]
    static let bitrateV2L1 = [
        32000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 144000, 160000, 176000, 192000, 224000, 256000,
    ]
    static let bitrateV1L2 = [
        32000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 160000, 192000, 224000, 256000, 320000, 384000,
    ]
    static let bitrateV1L3 = [
        32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 160000, 192000, 224000, 256000, 320000,
    ]
    static let bitrateV2 = [
        8000, 16000, 24000, 32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 144000, 160000,
    ]

    static func isMagicPresent(_ headerData: Int) -> Bool {
        headerData & 0xFFE0_0000 == 0xFFE0_0000
    }

    static func sampleRate(version: Int, samplingRateIndex: Int) -> Int {
        let sampleRate = samplingRateV1[samplingRateIndex]
        switch version {
        case 2: return sampleRate / 2 // MPEG-2.
        case 0: return sampleRate / 4 // MPEG-2.5.
        default: return sampleRate
        }
    }

    /// The bitrate of a frame. `layer` is 3 for layer I, 2 for layer II and 1 for layer III.
    static func bitrate(version: Int, layer: Int, bitrateIndex: Int) -> Int {
        switch (layer, version == 3) {
        case (3, true): bitrateV1L1[bitrateIndex - 1]
        case (3, false): bitrateV2L1[bitrateIndex - 1]
        case (2, true): bitrateV1L2[bitrateIndex - 1]
        case (_, true): bitrateV1L3[bitrateIndex - 1]
        default: bitrateV2[bitrateIndex - 1]
        }
    }

    static func frameSize(version: Int, layer: Int, bitrate: Int, sampleRate: Int, padding: Int) -> Int {
        if layer == 3 {
            // Layer I: slots of 4 bytes.
            return (12 * bitrate / sampleRate + padding) * 4
        }
        if version == 3 {
            return 144 * bitrate / sampleRate + padding
        }
        // Layer III of MPEG-2 and MPEG-2.5 has half the samples per frame.
        return (layer == 1 ? 72 : 144) * bitrate / sampleRate + padding
    }

    static func frameSizeInSamples(version: Int, layer: Int) -> Int {
        switch layer {
        case 1: version == 3 ? 1152 : 576 // Layer III.
        case 2: 1152 // Layer II.
        default: 384 // Layer I.
        }
    }
}

extension Format where Scope == FormatAttributes.Audio {
    /// The format of MPEG audio whose frames have `header`: they describe themselves, and the codec needs no config.
    init(header: MpegAudioUtil.Header) {
        self.init()
        self.codec = header.mimeType.map(AudioCodec.init)
        self.sampleRate = header.sampleRate
        self.channelCount = header.channels
    }
}
