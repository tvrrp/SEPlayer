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

    /// The layout of `tag` with a description of each of its channels.
    static func channelLayout(tag: AudioChannelLayoutTag) throws(AudioFormatError) -> ManagedAudioChannelLayout {
        var tag = tag
        return try withUnsafeBytes(of: &tag) { bytes throws(AudioFormatError) in
            try variableSizeLayout(kAudioFormatProperty_ChannelLayoutForTag, specifier: bytes)
        }
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
                return try .success(body(&info))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
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
                    return try .success(body(bytes))
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
