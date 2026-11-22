//
//  Ac3Util.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.Ac3Util
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

/// Reads AC-3 and E-AC-3 of ETSI TS 102 366: the decoder configurations of Annex F, the `dac3` and `dec3` boxes, and
/// the headers of sync frames.
enum Ac3Util {
    /// The samples of a frame of either.
    static let samplesPerFrame = 1536

    static let sampleRates = [48000, 44100, 32000]
    /// The full-bandwidth channels of each audio coding mode.
    static let channelCounts = [2, 1, 2, 3, 3, 4, 4, 5]
}

// MARK: - Sync frames

/// The sync frames of AC-3 and E-AC-3 streams, ETSI TS 102 366.
extension Ac3Util {
    /// The highest bitrate of AC-3, in bytes per second.
    static let ac3MaxRateBytesPerSecond = 640 * 1000 / 8
    /// The highest bitrate of E-AC-3, in bytes per second.
    static let eac3MaxRateBytesPerSecond = 6144 * 1000 / 8

    /// What the header of a sync frame says.
    struct SyncFrameInfo {
        /// The E-AC-3 stream type: independent (0), dependent (1) or AC-3 converted (2); `nil` for AC-3.
        enum StreamType: Int {
            case type0 = 0
            case type1 = 1
            case type2 = 2
        }

        /// `nil` for a frame that mustn't be decoded.
        let mimeType: MimeTypes?
        let streamType: StreamType?
        let channelCount: Int
        let sampleRate: Int
        let frameSize: Int
        let sampleCount: Int
        let bitrate: Int
    }

    /// Reads the header of the sync frame at the start of `data`, subsections 4.3 and E.1.2.
    static func parseAc3SyncFrameInfo(_ data: inout BlockBufferBitReader) throws -> SyncFrameInfo {
        let initialPosition = data.position
        data.skipBits(40)
        // The bitstream id tells AC-3 from E-AC-3 (subsections 4.3, E.1.2 and E.1.3.1.6).
        let isEac3 = try data.readBits(5) > 10
        data.setPosition(initialPosition)
        return isEac3 ? try parseEac3(&data) : try parseAc3(&data)
    }

    /// The size of the sync frame whose header starts `data`, or `nil` if the header isn't valid.
    static func parseAc3SyncFrameSize<C: RandomAccessCollection<UInt8>>(_ data: C) -> Int? where C.Index == Int {
        guard data.count >= 6 else { return nil }
        let start = data.startIndex
        let isEac3 = Int((data[start + 5] & 0xF8) >> 3) > 10
        if isEac3 {
            let frmsiz = Int(data[start + 2] & 0x07) << 8 | Int(data[start + 3])
            return (frmsiz + 1) * 2
        }
        let fscod = Int((data[start + 4] & 0xC0) >> 6)
        let frmsizecod = Int(data[start + 4] & 0x3F)
        return ac3SyncFrameSize(fscod: fscod, frmsizecod: frmsizecod)
    }

    /// The number of audio samples of the sync frame whose header starts `data`.
    static func parseAc3SyncFrameAudioSampleCount<C: RandomAccessCollection<UInt8>>(_ data: C) -> Int
    where C.Index == Int {
        let start = data.startIndex
        let isEac3 = Int((data[start + 5] & 0xF8) >> 3) > 10
        guard isEac3 else { return samplesPerFrame }
        let fscod = Int((data[start + 4] & 0xC0) >> 6)
        let numblkscod = fscod == 3 ? 3 : Int((data[start + 4] & 0x30) >> 4)
        return blocksPerSyncFrameByNumblkscod[numblkscod] * audioSamplesPerAudioBlock
    }
}

private extension Ac3Util {
    static let audioSamplesPerAudioBlock = 256
    static let blocksPerSyncFrameByNumblkscod = [1, 2, 3, 6]
    static let sampleRateByFscod2 = [24000, 22050, 16000]
    static let bitrateByHalfFrmsizecod = [
        32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640,
    ]
    static let syncFrameSizeWordsByHalfFrmsizecod441 = [
        69, 87, 104, 121, 139, 174, 208, 243, 278, 348, 417, 487, 557, 696, 835, 975, 1114, 1253, 1393,
    ]

    static func parseAc3(_ data: inout BlockBufferBitReader) throws -> SyncFrameInfo {
        data.skipBits(16 + 16) // syncword, crc1
        let fscod = try data.readBits(2)
        // fscod 3 says the decoder mustn't decode the audio: no MIME type keeps a renderer from taking it.
        let mimeType: MimeTypes? = fscod == 3 ? nil : .audioAC3
        let frmsizecod = try data.readBits(6)
        guard frmsizecod / 2 < bitrateByHalfFrmsizecod.count else {
            throw ParserError.createForMalformedContainer(message: "Invalid AC-3 frmsizecod \(frmsizecod)")
        }
        let bitrate = bitrateByHalfFrmsizecod[frmsizecod / 2] * 1000
        // -1 for a size and a rate fscod 3 leaves unknown.
        let frameSize = ac3SyncFrameSize(fscod: fscod, frmsizecod: frmsizecod) ?? -1
        data.skipBits(5 + 3) // bsid, bsmod
        let acmod = try data.readBits(3)
        if acmod & 0x01 != 0, acmod != 1 {
            data.skipBits(2) // cmixlev
        }
        if acmod & 0x04 != 0 {
            data.skipBits(2) // surmixlev
        }
        if acmod == 2 {
            data.skipBits(2) // dsurmod
        }
        let sampleRate = fscod < sampleRates.count ? sampleRates[fscod] : -1
        let lfeon = try data.readBit()
        return SyncFrameInfo(
            mimeType: mimeType,
            streamType: nil,
            channelCount: channelCounts[acmod] + (lfeon ? 1 : 0),
            sampleRate: sampleRate,
            frameSize: frameSize,
            sampleCount: samplesPerFrame,
            bitrate: bitrate
        )
    }

    static func parseEac3(_ data: inout BlockBufferBitReader) throws -> SyncFrameInfo {
        // Subsection E.1.2.
        data.skipBits(16) // syncword
        let streamType = try SyncFrameInfo.StreamType(rawValue: data.readBits(2)) // strmtyp
        data.skipBits(3) // substreamid
        let frameSize = try (data.readBits(11) + 1) * 2 // frmsiz, subsection E.1.3.1.3.
        let fscod = try data.readBits(2)
        let audioBlocks: Int
        let numblkscod: Int
        let sampleRate: Int
        if fscod == 3 {
            numblkscod = 3
            sampleRate = try sampleRateByFscod2[data.readBits(2)]
            audioBlocks = 6
        } else {
            numblkscod = try data.readBits(2)
            audioBlocks = blocksPerSyncFrameByNumblkscod[numblkscod]
            sampleRate = sampleRates[fscod]
        }
        let sampleCount = audioSamplesPerAudioBlock * audioBlocks
        let bitrate = (frameSize * sampleRate) / (audioBlocks * 32)
        let acmod = try data.readBits(3)
        let lfeon = try data.readBit()
        let channelCount = channelCounts[acmod] + (lfeon ? 1 : 0)
        data.skipBits(5 + 5) // bsid, dialnorm
        if try data.readBit() { // compre
            data.skipBits(8) // compr
        }
        if acmod == 0 {
            data.skipBits(5) // dialnorm2
            if try data.readBit() { // compr2e
                data.skipBits(8) // compr2
            }
        }
        if streamType == .type1, try data.readBit() { // chanmape
            data.skipBits(16) // chanmap
        }
        if try data.readBit() { // mixmdate
            try skipMixingMetadata(
                &data,
                acmod: acmod,
                lfeon: lfeon,
                streamType: streamType,
                numblkscod: numblkscod,
                audioBlocks: audioBlocks
            )
        }
        if try data.readBit() { // infomdate
            data.skipBits(3 + 1 + 1) // bsmod, copyrightb, origbs
            if acmod == 2 {
                data.skipBits(2 + 2) // dsurmod, dheadphonmod
            }
            if acmod >= 6 {
                data.skipBits(2) // dsurexmod
            }
            if try data.readBit() { // audioprodie
                data.skipBits(5 + 2 + 1) // mixlevel, roomtyp, adconvtyp
            }
            if acmod == 0, try data.readBit() { // audioprodi2e
                data.skipBits(5 + 2 + 1) // mixlevel2, roomtyp2, adconvtyp2
            }
            if fscod < 3 {
                data.skipBit() // sourcefscod
            }
        }
        if streamType == .type0, numblkscod != 3 {
            data.skipBit() // convsync
        }
        if streamType == .type2 {
            let hasBlockId = try numblkscod == 3 || data.readBit() // blkid
            if hasBlockId {
                data.skipBits(6) // frmsizecod
            }
        }
        var mimeType = MimeTypes.audioEAC3
        if try data.readBit() { // addbsie
            let addbsil = try data.readBits(6)
            if try addbsil == 1 && data.readBits(8) == 1 { // addbsi
                mimeType = .audioEAC3JOC
            }
        }
        return SyncFrameInfo(
            mimeType: mimeType,
            streamType: streamType,
            channelCount: channelCount,
            sampleRate: sampleRate,
            frameSize: frameSize,
            sampleCount: sampleCount,
            bitrate: bitrate
        )
    }

    static func skipMixingMetadata(
        _ data: inout BlockBufferBitReader,
        acmod: Int,
        lfeon: Bool,
        streamType: SyncFrameInfo.StreamType?,
        numblkscod: Int,
        audioBlocks: Int
    ) throws {
        if acmod > 2 {
            data.skipBits(2) // dmixmod
        }
        if acmod & 0x01 != 0, acmod > 2 {
            data.skipBits(3 + 3) // ltrtcmixlev, lorocmixlev
        }
        if acmod & 0x04 != 0 {
            data.skipBits(6) // ltrtsurmixlev, lorosurmixlev
        }
        if lfeon, try data.readBit() { // lfemixlevcode
            data.skipBits(5) // lfemixlevcod
        }
        guard streamType == .type0 else { return }

        if try data.readBit() { // pgmscle
            data.skipBits(6) // pgmscl
        }
        if acmod == 0, try data.readBit() { // pgmscl2e
            data.skipBits(6) // pgmscl2
        }
        if try data.readBit() { // extpgmscle
            data.skipBits(6) // extpgmscl
        }
        let mixdef = try data.readBits(2)
        if mixdef == 1 {
            data.skipBits(1 + 1 + 3) // premixcmpsel, drcsrc, premixcmpscl
        } else if mixdef == 2 {
            data.skipBits(12) // mixdata
        } else if mixdef == 3 {
            let mixdeflen = try data.readBits(5)
            if try data.readBit() { // mixdata2e
                data.skipBits(1 + 1 + 3) // premixcmpsel, drcsrc, premixcmpscl
                // extpgmlscle, extpgmcscle, extpgmrscle, extpgmlsscle, extpgmrsscle, extpgmlfescle, dmixscle.
                for _ in 0 ..< 7 where try data.readBit() {
                    data.skipBits(4)
                }
                if try data.readBit() { // addche
                    // extpgmaux1scle, extpgmaux2scle.
                    for _ in 0 ..< 2 where try data.readBit() {
                        data.skipBits(4)
                    }
                }
            }
            if try data.readBit() { // mixdata3e
                data.skipBits(5) // spchdat
                if try data.readBit() { // addspchdate
                    data.skipBits(5 + 2) // spchdat1, spchan1att
                    if try data.readBit() { // addspdat1e
                        data.skipBits(5 + 3) // spchdat2, spchan2att
                    }
                }
            }
            data.skipBits(8 * (mixdeflen + 2)) // mixdata
            data.byteAlign() // mixdatafill
        }
        if acmod < 2 {
            if try data.readBit() { // paninfoe
                data.skipBits(8 + 6) // panmean, paninfo
            }
            if acmod == 0, try data.readBit() { // paninfo2e
                data.skipBits(8 + 6) // panmean2, paninfo2
            }
        }
        if try data.readBit() { // frmmixcfginfoe
            if numblkscod == 0 {
                data.skipBits(5) // blkmixcfginfo[0]
            } else {
                for _ in 0 ..< audioBlocks where try data.readBit() { // blkmixcfginfoe
                    data.skipBits(5) // blkmixcfginfo[blk]
                }
            }
        }
    }

    static func ac3SyncFrameSize(fscod: Int, frmsizecod: Int) -> Int? {
        let halfFrmsizecod = frmsizecod / 2
        guard fscod >= 0, fscod < sampleRates.count, frmsizecod >= 0,
              halfFrmsizecod < syncFrameSizeWordsByHalfFrmsizecod441.count else {
            return nil
        }
        let sampleRate = sampleRates[fscod]
        if sampleRate == 44100 {
            return 2 * (syncFrameSizeWordsByHalfFrmsizecod441[halfFrmsizecod] + (frmsizecod % 2))
        }
        let bitrate = bitrateByHalfFrmsizecod[halfFrmsizecod]
        return sampleRate == 32000 ? 6 * bitrate : 4 * bitrate
    }
}

extension CodecAttributes where Scope == AudioCodec.AC3 {
    /// The rate of `fscod`, or `nil` for a reserved code.
    var sampleRate: Int? {
        self.sampleRateCode.flatMap { Ac3Util.sampleRates.indices.contains($0) ? Ac3Util.sampleRates[$0] : nil }
    }

    /// The full range channels of `acmod`, and the low frequency one.
    var channelCount: Int? {
        self.audioCodingMode.map { Ac3Util.channelCounts[$0 & 0x07] + (self.hasLowFrequencyEffects == true ? 1 : 0) }
    }

    /// Reads an `AC3SpecificBox`: fscod (2), bsid (5), bsmod (3), acmod (3), lfeon (1), bit_rate_code (5),
    /// reserved (5).
    ///
    /// - Parameter box: The payload of a `dac3` box, its indices starting at 0.
    init(dac3 box: BlockBufferReader) throws {
        var bits = BlockBufferBitReader(reader: box)
        self.init()
        self.sampleRateCode = try bits.readBits(2)
        self.bitstreamID = try bits.readBits(5)
        self.bitstreamMode = try bits.readBits(3)
        self.audioCodingMode = try bits.readBits(3)
        self.hasLowFrequencyEffects = try bits.readBit()
        self.bitRateCode = try bits.readBits(5)
    }
}

extension CodecAttributes where Scope == AudioCodec.EAC3 {
    /// The highest rate of the independent substreams, or `nil` when one has a reserved code.
    var sampleRate: Int? {
        guard let substreams = self.substreams, !substreams.isEmpty,
              substreams.allSatisfy({ Ac3Util.sampleRates.indices.contains($0.sampleRateCode) }) else {
            return nil
        }
        return substreams.map { Ac3Util.sampleRates[$0.sampleRateCode] }.max()
    }

    /// The channels of the last independent substream, with those its dependent substreams add.
    var channelCount: Int? {
        guard let substream = self.substreams?.last else { return nil }
        var count = Ac3Util.channelCounts[substream.audioCodingMode & 0x07] + (substream.hasLowFrequencyEffects ? 1 : 0)
        guard substream.dependentSubstreamCount > 0 else { return count }
        // The channels of each bit of chan_loc: pairs, or single ones.
        for (bit, channels) in [2, 2, 1, 1, 2, 2, 2, 1, 1].enumerated() where substream.channelLocations & (1 << bit) != 0 {
            // A centre surround the independent substream already has isn't added twice.
            let isRepeatedCentreSurround = bit == 2 && [4, 5].contains(substream.audioCodingMode)
            count += isRepeatedCentreSurround ? 0 : channels
        }
        return count
    }

    /// Reads an `EC3SpecificBox`: data_rate (13), num_ind_sub (3), then each independent substream, and for Dolby
    /// Atmos the complexity of its joint object coding.
    ///
    /// - Parameter box: The payload of a `dec3` box, its indices starting at 0.
    init(dec3 box: BlockBufferReader) throws {
        var bits = BlockBufferBitReader(reader: box)
        self.init()
        self.dataRate = try bits.readBits(13)
        let independentSubstreamCount = try bits.readBits(3) + 1
        var substreams: [AudioCodec.EAC3.Substream] = []
        for _ in 0 ..< independentSubstreamCount {
            // fscod (2), bsid (5), reserved (1), asvc (1), bsmod (3), acmod (3), lfeon (1), reserved (3),
            // num_dep_sub (4), then chan_loc (9) with dependent substreams or reserved (1).
            let sampleRateCode = try bits.readBits(2)
            let bitstreamID = try bits.readBits(5)
            bits.skipBit()
            let isAudioServiceMixed = try bits.readBit()
            let bitstreamMode = try bits.readBits(3)
            let audioCodingMode = try bits.readBits(3)
            let hasLowFrequencyEffects = try bits.readBit()
            bits.skipBits(3)
            let dependentSubstreamCount = try bits.readBits(4)
            var channelLocations = 0
            if dependentSubstreamCount > 0 {
                channelLocations = try bits.readBits(9)
            } else {
                bits.skipBit()
            }
            substreams.append(AudioCodec.EAC3.Substream(
                sampleRateCode: sampleRateCode,
                bitstreamID: bitstreamID,
                isAudioServiceMixed: isAudioServiceMixed,
                bitstreamMode: bitstreamMode,
                audioCodingMode: audioCodingMode,
                hasLowFrequencyEffects: hasLowFrequencyEffects,
                dependentSubstreamCount: dependentSubstreamCount,
                channelLocations: channelLocations
            ))
        }
        self.substreams = substreams

        // reserved (7), flag_ec3_extension_type_a (1), complexity_index_type_a (8).
        if bits.bitsLeft >= 16 {
            bits.skipBits(7)
            if try bits.readBit() {
                self.jointObjectCodingComplexity = try bits.readBits(8)
            }
        }
    }
}
