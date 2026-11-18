//
//  AudioFormatProperties.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import AudioToolbox
import CoreAudio
import Foundation
import SEPlayerCommon

/// A failure of the audio format services to describe a format.
struct AudioFormatError: Error, Hashable, Sendable, CustomNSError {
    let status: OSStatus

    static var errorDomain: String { NSOSStatusErrorDomain }
    var errorCode: Int { Int(status) }

    /// The services described no format.
    static let noFormats = Self(status: kAudioFormatUnknownFormatError)
    /// The bytes given couldn't be read as one piece.
    static let unreadableBytes = Self(status: kAudioFormatBadSpecifierSizeError)
}

/// What the audio format services know about formats.
enum AudioFormatProperties {
    /// The stream description and the magic cookie of an MPEG-4 elementary stream descriptor, the payload of an
    /// `esds` box after its version and flags.
    ///
    /// - Returns: The description, and the part of `esds` that is the stream's magic cookie, if it has one.
    static func formatInfo(esds: BlockBufferReader) throws(AudioFormatError) -> (AudioStreamBasicDescription, BlockBufferReader?) {
        var info = AudioFormatInfo(mASBD: AudioStreamBasicDescription(), mMagicCookie: noCookie, mMagicCookieSize: 0)
        var size = UInt32(MemoryLayout<AudioFormatInfo>.size)
        // The cookie is a part of the descriptor: it is kept as offsets, its pointer being valid only here.
        var cookieRange: Range<Int>?
        let status = try withBytes(of: esds) { bytes in
            let status = AudioFormatGetProperty(.esdsFormatInfo, UInt32(bytes.count), bytes.baseAddress, &size, &info)
            if status == noErr, let base = bytes.baseAddress, info.mMagicCookieSize > 0 {
                let start = info.mMagicCookie - base
                let end = start + Int(info.mMagicCookieSize)
                if start >= 0, end <= bytes.count { cookieRange = start..<end }
            }
            return status
        }
        guard status == noErr else { throw AudioFormatError(status: status) }
        let cookie = cookieRange.flatMap { try? esds.getSlice(at: esds.readerIndex + $0.lowerBound, length: $0.count) }
        return (info.mASBD, cookie)
    }

    /// The stream description of the `esds` decoder config of an MPEG-4 audio stream.
    static func mpeg4StreamDescription(esds: BlockBufferReader) throws(AudioFormatError) -> AudioStreamBasicDescription {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = try withBytes(of: esds) { bytes in
            AudioFormatGetProperty(kAudioFormatProperty_ASBDFromESDS, UInt32(bytes.count), bytes.baseAddress, &size, &description)
        }
        guard status == noErr else { throw AudioFormatError(status: status) }
        return description
    }

    /// The channel layout of the `esds` decoder config of an MPEG-4 audio stream.
    static func mpeg4ChannelLayout(esds: BlockBufferReader) throws(AudioFormatError) -> ManagedAudioChannelLayout {
        try withBytes(of: esds) { bytes throws(AudioFormatError) in
            try variableSizeLayout(kAudioFormatProperty_ChannelLayoutFromESDS, specifier: bytes)
        }
    }

    /// `description` completed with what `magicCookie` tells, such as the frames per packet.
    static func formatInfo(
        description: AudioStreamBasicDescription,
        magicCookie: BlockBufferReader?
    ) throws(AudioFormatError) -> AudioStreamBasicDescription {
        var description = description
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = try withBytes(of: magicCookie) { cookie in
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count), cookie.baseAddress, &size, &description)
        }
        guard status == noErr else { throw AudioFormatError(status: status) }
        return description
    }

    /// The formats a stream of `description` with `magicCookie` can be decoded to, the richest first, such as the
    /// layers of HE-AAC.
    static func formatList(
        description: AudioStreamBasicDescription,
        magicCookie: BlockBufferReader?
    ) throws(AudioFormatError) -> [AudioFormatListItem] {
        try withFormatInfo(description: description, magicCookie: magicCookie) { info throws(AudioFormatError) in
            let infoSize = UInt32(MemoryLayout<AudioFormatInfo>.size)
            var listSize: UInt32 = 0
            var status = AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, infoSize, &info, &listSize)
            guard status == noErr else {
                throw AudioFormatError(status: status)
            }

            let itemSize = MemoryLayout<AudioFormatListItem>.size
            var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: Int(listSize) / itemSize)
            status = items.withUnsafeMutableBytes { bytes in
                AudioFormatGetProperty(kAudioFormatProperty_FormatList, infoSize, &info, &listSize, bytes.baseAddress)
            }
            guard status == noErr else {
                throw AudioFormatError(status: status)
            }

            let count = Int(listSize) / itemSize
            guard count > 0 else { throw .noFormats }
            return Array(items.prefix(count))
        }
    }

    /// The index of the first format of `list` this system can play.
    static func firstPlayableFormat(in list: [AudioFormatListItem]) throws(AudioFormatError) -> Int {
        var index: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = list.withUnsafeBytes { bytes in
            AudioFormatGetProperty(kAudioFormatProperty_FirstPlayableFormatFromList, UInt32(bytes.count), bytes.baseAddress, &size, &index)
        }
        guard status == noErr else { throw AudioFormatError(status: status) }
        return Int(index)
    }

    /// The channel layout a decoder of `description` with `magicCookie` gives its channels.
    static func channelLayout(
        description: AudioStreamBasicDescription,
        magicCookie: BlockBufferReader?
    ) throws(AudioFormatError) -> ManagedAudioChannelLayout {
        try withFormatInfo(description: description, magicCookie: magicCookie) { info throws(AudioFormatError) in
            try withUnsafeBytes(of: &info) { bytes throws(AudioFormatError) in
                try variableSizeLayout(.channelLayoutFromFormatInfo, specifier: bytes)
            }
        }
    }

    /// The channel layout of an ISO channel layout box, `chnl`, for linear PCM of `description`.
    ///
    /// - Parameter channelLayoutBox: The whole `chnl` box, from its size field.
    static func channelLayout(
        description: AudioStreamBasicDescription,
        channelLayoutBox: BlockBufferReader
    ) throws(AudioFormatError) -> ManagedAudioChannelLayout {
        try withFormatInfo(description: description, magicCookie: channelLayoutBox) { info throws(AudioFormatError) in
            try withUnsafeBytes(of: &info) { bytes throws(AudioFormatError) in
                try variableSizeLayout(.channelLayoutFromDecoderConfig, specifier: bytes)
            }
        }
    }

    /// The layout tag that names the channels of `layout`.
    static func tag(for layout: ManagedAudioChannelLayout) throws(AudioFormatError) -> AudioChannelLayoutTag {
        var tag: AudioChannelLayoutTag = 0
        var size = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        let status = layout.withUnsafeLayout { pointer, layoutSize in
            AudioFormatGetProperty(kAudioFormatProperty_TagForChannelLayout, UInt32(layoutSize), pointer, &size, &tag)
        }
        guard status == noErr else { throw AudioFormatError(status: status) }
        return tag
    }

    // MARK: - Helpers

    /// A property whose value is a channel layout of any size, for `specifier`.
    private static func variableSizeLayout(
        _ property: AudioFormatPropertyID,
        specifier: UnsafeRawBufferPointer
    ) throws(AudioFormatError) -> ManagedAudioChannelLayout {
        var size: UInt32 = 0
        var status = AudioFormatGetPropertyInfo(property, UInt32(specifier.count), specifier.baseAddress, &size)
        guard status == noErr else { throw AudioFormatError(status: status) }
        var layout = [UInt8](repeating: 0, count: Int(size))
        status = layout.withUnsafeMutableBytes { bytes in
            AudioFormatGetProperty(property, UInt32(specifier.count), specifier.baseAddress, &size, bytes.baseAddress)
        }
        guard status == noErr else { throw AudioFormatError(status: status) }
        let managed = layout.prefix(Int(size)).withUnsafeBytes { ManagedAudioChannelLayout(layoutBytes: $0) }
        guard let managed else { throw .noFormats }
        return managed
    }

    /// Calls `body` with a format info of `description` and `magicCookie`, valid only meanwhile.
    private static func withFormatInfo<R>(
        description: AudioStreamBasicDescription,
        magicCookie: BlockBufferReader?,
        _ body: (inout AudioFormatInfo) throws(AudioFormatError) -> R
    ) throws(AudioFormatError) -> R {
        let result: Result<R, AudioFormatError> = try withBytes(of: magicCookie) { cookie in
            var info = AudioFormatInfo(
                mASBD: description,
                mMagicCookie: cookie.baseAddress ?? noCookie,
                mMagicCookieSize: UInt32(cookie.count)
            )
            do throws(AudioFormatError) {
                return .success(try body(&info))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    // MARK: - Codec registry

    /// The containers whose sample entries the format services know codecs of.
    enum ContainerFlavor: UInt32 {
        /// ISO files, MP4 and 3GPP alike.
        case isoFamily = 0x6D70_3466 // 'mp4f'
        case quickTimeMovie = 0x4D6F_6F56 // 'MooV'
    }

    /// The format a decoder decodes the sample entries of `codingName` to, when there is a single one.
    static func decodeFormat(codingName: UInt32, flavor: ContainerFlavor) -> AudioFormatID? {
        guard let formats = try? registryLookup(.decodeFormatsForCodingName, flavor: flavor, code: codingName, as: AudioFormatID.self),
              formats.count == 1 else {
            return nil
        }
        return formats[0]
    }

    /// The type of the box that carries the decoder config of sample entries of `codingName`, such as `dapa` of
    /// `apac`.
    static func configBoxType(codingName: UInt32, flavor: ContainerFlavor) -> UInt32? {
        // The flavor, the size of the type, and the type.
        guard let fields = try? registryLookup(.configBoxForCodingName, flavor: flavor, code: codingName, as: UInt32.self),
              fields.count == 3 else {
            return nil
        }
        return fields[2]
    }

    /// The format a decoder decodes the config of a box of `boxType` to, when there is a single one.
    static func decodeFormat(configBoxType boxType: UInt32, flavor: ContainerFlavor) -> AudioFormatID? {
        guard let formats = try? registryLookup(.decodeFormatsForConfigBox, flavor: flavor, code: boxType, as: AudioFormatID.self),
              formats.count == 1 else {
            return nil
        }
        return formats[0]
    }

    /// The magic cookie a decoder of `format` takes, from the whole box of its config.
    static func canonicalMagicCookie(
        configBox box: BlockBufferReader,
        format: AudioFormatID,
        flavor: ContainerFlavor
    ) throws(AudioFormatError) -> BlockBufferReader {
        let cookie: [UInt8] = try withBytes(of: box) { (bytes) throws(AudioFormatError) -> [UInt8] in
            guard let base = bytes.baseAddress else { throw .unreadableBytes }
            var specifier = CanonicalCookieSpecifier(format: format, flavor: flavor.rawValue, config: base, configSize: UInt32(bytes.count))
            let specifierSize = UInt32(MemoryLayout<CanonicalCookieSpecifier>.size)
            var size: UInt32 = 0
            var status = AudioFormatGetPropertyInfo(.canonicalMagicCookie, specifierSize, &specifier, &size)
            guard status == noErr else {
                throw AudioFormatError(status: status)
            }
            var cookie = [UInt8](repeating: 0, count: Int(size))
            status = AudioFormatGetProperty(.canonicalMagicCookie, specifierSize, &specifier, &size, &cookie)
            guard status == noErr else {
                throw AudioFormatError(status: status)
            }
            return Array(cookie.prefix(Int(size)))
        }
        do {
            return try BlockBufferReader(bytes: cookie)
        } catch {
            throw .unreadableBytes
        }
    }

    /// A lookup of the codec registry: a container flavor and a four character code in, values of `T` out.
    private static func registryLookup<T: FixedWidthInteger>(
        _ property: AudioFormatPropertyID,
        flavor: ContainerFlavor,
        code: UInt32,
        as: T.Type
    ) throws(AudioFormatError) -> [T] {
        var specifier = RegistrySpecifier(flavor: flavor.rawValue, codeSize: UInt32(MemoryLayout<UInt32>.size), code: code)
        let specifierSize = UInt32(MemoryLayout<RegistrySpecifier>.size)
        var size: UInt32 = 0
        var status = AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size)
        guard status == noErr else { throw AudioFormatError(status: status) }
        var values = [T](repeating: 0, count: Int(size) / MemoryLayout<T>.size)
        status = values.withUnsafeMutableBytes { values in
            AudioFormatGetProperty(property, specifierSize, &specifier, &size, values.baseAddress!)
        }
        guard status == noErr else { throw AudioFormatError(status: status) }
        return values
    }

    private struct RegistrySpecifier {
        var flavor: UInt32
        var codeSize: UInt32
        var code: UInt32
    }

    private struct CanonicalCookieSpecifier {
        var format: AudioFormatID
        var flavor: UInt32
        var config: UnsafeRawPointer
        var configSize: UInt32
        var reserved: UInt32 = 0
    }

    /// Calls `body` with the readable bytes of `reader` in one piece, or no bytes without a reader.
    private static func withBytes<R>(
        of reader: BlockBufferReader?,
        _ body: (UnsafeRawBufferPointer) throws(AudioFormatError) -> R
    ) throws(AudioFormatError) -> R {
        guard let reader, reader.readableBytes > 0 else {
            return try body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        let result: Result<R, AudioFormatError>
        do {
            result = try reader.withUnsafeReadableBuffer { bytes in
                do throws(AudioFormatError) {
                    return .success(try body(bytes))
                } catch {
                    return .failure(error)
                }
            }
        } catch {
            throw .unreadableBytes
        }
        return try result.get()
    }

    /// The cookie pointer of a format info without a cookie, whose size is zero.
    private static let noCookie = UnsafeRawPointer(bitPattern: 1)!
}

/// Properties the format services answer that `AudioFormat.h` doesn't declare.
private extension AudioFormatPropertyID {
    /// The stream description and magic cookie of an `esds` decoder config: an `AudioFormatInfo` whose cookie points
    /// into the config.
    static let esdsFormatInfo: AudioFormatPropertyID = 0x6573_6669 // 'esfi'
    /// The channel layout a decoder gives the channels of a format, from an `AudioFormatInfo`.
    static let channelLayoutFromFormatInfo: AudioFormatPropertyID = 0x636C_6669 // 'clfi'
    /// The channel layout of a decoder config that describes one, such as an ISO `chnl` box, from an
    /// `AudioFormatInfo` whose cookie is the config.
    static let channelLayoutFromDecoderConfig: AudioFormatPropertyID = 0x6463_636C // 'dccl'
    /// The formats that decode sample entries of a coding name, from a `RegistrySpecifier`.
    static let decodeFormatsForCodingName: AudioFormatPropertyID = 0x6964_636E // 'idcn'
    /// The flavor, the size of the type and the type of the box that carries the decoder config of a coding name,
    /// from a `RegistrySpecifier`.
    static let configBoxForCodingName: AudioFormatPropertyID = 0x656E_636E // 'encn'
    /// The formats that decode the config of a box type, from a `RegistrySpecifier`.
    static let decodeFormatsForConfigBox: AudioFormatPropertyID = 0x6964_656E // 'iden'
    /// The magic cookie of a format from the whole box of its config, from a `CanonicalCookieSpecifier`.
    static let canonicalMagicCookie: AudioFormatPropertyID = 0x6D63_6563 // 'mcec'
}
