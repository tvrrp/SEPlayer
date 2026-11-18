//
//  ProtectionScheme.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import CoreMedia
import SEPlayerCommon

/// The protection of a sample entry, as its `sinf` box describes it: the format of the media before protection, and
/// the Common Encryption scheme of ISO/IEC 23001-7 with its track encryption box.
struct ProtectionScheme {
    /// The Common Encryption schemes of version 1.0 that format descriptions describe.
    static let schemeTypes: Set<MP4Box.BoxType> = [.cenc, .cbc2, .cbcs]

    /// The format of the `frma` box, unless it is zero.
    let originalFormat: UInt32?
    /// The scheme of the `schm` box, when it is a Common Encryption scheme of version 1.0.
    let schemeType: MP4Box.BoxType?
    /// The payload of the `tenc` box in the `schi` box, from its version, when it holds a key identifier.
    let trackEncryptionBox: BlockBufferReader?

    /// The size of a `tenc` payload of version 0: version and flags (4), reserved (2), isProtected (1),
    /// Per_Sample_IV_Size (1), default_KID (16).
    private static let minimumTrackEncryptionSize = 24
    private static let schemeVersion: UInt32 = 0x0001_0000

    /// - Parameter sinf: The payload of the `sinf` box, its indices starting at 0.
    init(sinf: BlockBufferReader) {
        let boxes = SampleEntryBox.boxes(in: sinf, from: sinf.readerIndex).boxes
        func payload(_ type: MP4Box.BoxType, in boxes: [SampleEntryBox]) -> BlockBufferReader? {
            boxes.first { $0.type == type }?.payload
        }

        if let frma = payload(.frma, in: boxes), frma.readableBytes == 4,
           let format = try? frma.getInt(at: frma.readerIndex, as: UInt32.self), format != 0 {
            originalFormat = format
        } else {
            originalFormat = nil
        }

        // schm: version and flags (4), scheme_type (4), scheme_version (4).
        if let schm = payload(.schm, in: boxes), schm.readableBytes >= 12,
           let type = try? schm.getInt(at: schm.readerIndex + 4, as: UInt32.self),
           let version = try? schm.getInt(at: schm.readerIndex + 8, as: UInt32.self),
           version == Self.schemeVersion,
           let scheme = MP4Box.BoxType(rawValue: type), Self.schemeTypes.contains(scheme) {
            schemeType = scheme
        } else {
            schemeType = nil
        }

        if let schi = payload(.schi, in: boxes),
           let tenc = payload(.tenc, in: SampleEntryBox.boxes(in: schi, from: schi.readerIndex).boxes),
           tenc.readableBytes >= Self.minimumTrackEncryptionSize {
            trackEncryptionBox = tenc
        } else {
            trackEncryptionBox = nil
        }
    }

    /// Adds what a Common Encryption scheme tells: that the media is protected, its original format and its track
    /// encryption box. A scheme of another kind adds nothing, and an earlier `sinf` box wins.
    func addExtensions(to extensions: inout SampleDescriptionExtensions) throws {
        guard schemeType != nil else { return }
        extensions.addFirst(kCFBooleanTrue as Any, for: SampleDescriptionExtensionKey.commonEncryptionProtected)
        if let originalFormat {
            extensions.addFirst(
                SampleDescriptionExtensions.number(Int32(bitPattern: originalFormat)),
                for: SampleDescriptionExtensionKey.commonEncryptionOriginalFormat
            )
        }
        if let trackEncryptionBox {
            extensions.addFirst(try Data(buffer: trackEncryptionBox), for: SampleDescriptionExtensionKey.commonEncryptionTrackEncryptionBox)
        }
    }

    // MARK: - Codec types

    /// The codec type of protected video, named by its original format and scheme, as decoders of protected media
    /// know it: `cavc` for H.264 in `cenc`, `qavc` in `cbcs` or `cbc2`, and alike for H.265, Dolby Vision, AV1 and
    /// VP9.
    ///
    /// - Returns: `nil` for a format and scheme with no such type, which stay `encv`.
    var protectedVideoCodecType: MP4Box.BoxType? {
        guard let originalFormat, let schemeType,
              let format = MP4Box.BoxType(rawValue: originalFormat) else {
            return nil
        }
        let isCounterMode = schemeType == .cenc
        switch format {
        case .avc1: return isCounterMode ? .cavc : .qavc
        case .avc3: return isCounterMode ? .cavc : .qave
        case .hvc1: return isCounterMode ? .chvc : .qhvc
        case .hev1: return isCounterMode ? .chvc : .qhev
        case .dvh1: return isCounterMode ? .cdh1 : .qdh1
        case .dvhe: return isCounterMode ? .cdh1 : .qdhe
        case .av01 where schemeType == .cbcs: return .qav1
        case .dav1 where schemeType == .cbcs: return .qdav
        case .vp09 where schemeType == .cbcs: return .qvp9
        default: return nil
        }
    }

    /// The format of protected audio, by the format its decoder describes; the scheme doesn't matter.
    ///
    /// - Returns: `nil` for a format with no protected variant.
    static func protectedAudioFormat(_ format: AudioFormatID) -> AudioFormatID? {
        switch format {
        case kAudioFormatMPEG4AAC: MP4Box.BoxType.qaac.rawValue
        case kAudioFormatAC3: MP4Box.BoxType.qac3.rawValue
        case kAudioFormatEnhancedAC3: MP4Box.BoxType.qec3.rawValue
        case kAudioFormatAppleLossless: MP4Box.BoxType.qlac.rawValue
        case kAudioFormatFLAC: MP4Box.BoxType.qflc.rawValue
        case MP4Box.BoxType.apac.rawValue: MP4Box.BoxType.qapc.rawValue
        default: nil
        }
    }
}
