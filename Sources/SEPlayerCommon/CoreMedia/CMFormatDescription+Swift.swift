//
//  CMFormatDescription+Swift.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import CoreAudio
import CoreMedia
import CoreVideo
import Foundation

public extension _CoreMediaInitializable where Self == CMFormatDescription {
    /// A format description of media without more details than its type, such as text.
    ///
    /// - Parameter extensions: Format description extensions, by their keys.
    init(
        mediaType: CMFormatDescription.MediaType,
        mediaSubType: CMFormatDescription.MediaSubType,
        extensions: [CFString: Any]? = nil
    ) throws(FormatDescriptionError) {
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: mediaType.rawValue,
            mediaSubType: mediaSubType.rawValue,
            extensions: extensions as CFDictionary?,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    /// An audio format description.
    ///
    /// - Parameters:
    ///   - layout: Which channel is which; the default order of the channel count without it.
    ///   - magicCookie: What the decoder needs besides the stream description, such as an `esds` decoder config.
    init(
        audioStreamBasicDescription: AudioStreamBasicDescription,
        layout: ManagedAudioChannelLayout? = nil,
        magicCookie: Data? = nil,
        extensions: [CFString: Any]? = nil
    ) throws(FormatDescriptionError) {
        var description: CMFormatDescription?
        let status = withUnsafePointer(to: audioStreamBasicDescription) { basicDescription in
            Self.withLayout(layout) { layout, layoutSize in
                Self.withBytes(of: magicCookie) { cookie in
                    CMAudioFormatDescriptionCreate(
                        allocator: kCFAllocatorDefault,
                        asbd: basicDescription,
                        layoutSize: layoutSize,
                        layout: layout,
                        magicCookieSize: cookie.count,
                        magicCookie: cookie.baseAddress,
                        extensions: extensions as CFDictionary?,
                        formatDescriptionOut: &description
                    )
                }
            }
        }
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    /// An audio format description whose magic cookie is the readable bytes of a reader.
    ///
    /// - Parameters:
    ///   - layout: Which channel is which; the default order of the channel count without it.
    ///   - magicCookie: What the decoder needs besides the stream description, such as an `esds` decoder config.
    init(
        audioStreamBasicDescription: AudioStreamBasicDescription,
        layout: ManagedAudioChannelLayout?,
        magicCookie: BlockBufferReader?,
        extensions: [CFString: Any]?
    ) throws(FormatDescriptionError) {
        guard let magicCookie, magicCookie.readableBytes > 0 else {
            try self.init(audioStreamBasicDescription: audioStreamBasicDescription, layout: layout, magicCookie: Data?.none, extensions: extensions)
            return
        }
        var description: CMFormatDescription?
        let status: OSStatus
        do {
            status = try magicCookie.withUnsafeReadableBuffer { cookie in
                withUnsafePointer(to: audioStreamBasicDescription) { basicDescription in
                    Self.withLayout(layout) { layout, layoutSize in
                        CMAudioFormatDescriptionCreate(
                            allocator: kCFAllocatorDefault,
                            asbd: basicDescription,
                            layoutSize: layoutSize,
                            layout: layout,
                            magicCookieSize: cookie.count,
                            magicCookie: cookie.baseAddress,
                            extensions: extensions as CFDictionary?,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        } catch {
            throw .allocationFailed
        }
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    /// An H.264 format description from its parameter sets, sequence ones first.
    ///
    /// - Parameter nalUnitHeaderLength: The size of the length before each NAL unit of the samples.
    init(h264ParameterSets: [Data], nalUnitHeaderLength: Int) throws(FormatDescriptionError) {
        var description: CMFormatDescription?
        let status = Self.withParameterSets(h264ParameterSets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers.baseAddress!,
                parameterSetSizes: sizes.baseAddress!,
                nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    /// An HEVC format description from its parameter sets: video, sequence and picture ones.
    init(hevcParameterSets: [Data], nalUnitHeaderLength: Int, extensions: [CFString: Any]? = nil) throws(FormatDescriptionError) {
        var description: CMFormatDescription?
        let status = Self.withParameterSets(hevcParameterSets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers.baseAddress!,
                parameterSetSizes: sizes.baseAddress!,
                nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                extensions: extensions as CFDictionary?,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    /// A video format description of the size and pixel format of `imageBuffer`.
    init(imageBuffer: CVImageBuffer) throws(FormatDescriptionError) {
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    /// A video format description of a codec and a size, for decoders that need nothing else.
    init(
        videoCodecType: CMFormatDescription.MediaSubType,
        width: Int,
        height: Int,
        extensions: [CFString: Any]? = nil
    ) throws(FormatDescriptionError) {
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: videoCodecType.rawValue,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary?,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    /// An audio format description from a big-endian sound sample description, such as the `stsd` entry of an MP4
    /// track.
    ///
    /// - Parameter flavor: The container's flavor of sample descriptions: QuickTime's, or ISO's when `nil`.
    init(bigEndianSoundDescription: CMBlockBuffer, flavor: CMSoundDescriptionFlavor?) throws(FormatDescriptionError) {
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionBlockBuffer(
            allocator: kCFAllocatorDefault,
            bigEndianSoundDescriptionBlockBuffer: bigEndianSoundDescription,
            flavor: flavor,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    /// A video format description from a big-endian image sample description, such as the `stsd` entry of an MP4
    /// track.
    ///
    /// - Parameter flavor: The container's flavor of sample descriptions: QuickTime's, or ISO's when `nil`.
    init(
        bigEndianImageDescription: CMBlockBuffer,
        stringEncoding: CFStringEncoding = CFStringGetSystemEncoding(),
        flavor: CMImageDescriptionFlavor?
    ) throws(FormatDescriptionError) {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionBlockBuffer(
            allocator: kCFAllocatorDefault,
            bigEndianImageDescriptionBlockBuffer: bigEndianImageDescription,
            stringEncoding: stringEncoding,
            flavor: flavor,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw FormatDescriptionError(status: status)
        }
        self = description
    }

    private static func withLayout<R>(
        _ layout: ManagedAudioChannelLayout?,
        _ body: (UnsafePointer<AudioChannelLayout>?, Int) -> R
    ) -> R {
        guard let layout else { return body(nil, 0) }
        return layout.withUnsafeLayout { body($0, $1) }
    }

    private static func withBytes<R>(of data: Data?, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        guard let data, !data.isEmpty else {
            return body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return data.withUnsafeBytes(body)
    }

    /// Calls `body` with pointers to the bytes of `parameterSets` and their sizes.
    private static func withParameterSets<R>(
        _ parameterSets: [Data],
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>>, UnsafeBufferPointer<Int>) -> R
    ) -> R {
        // One allocation for all of them, so the pointers stay valid together.
        let joined = parameterSets.reduce(into: Data()) { $0.append($1) }
        return joined.withUnsafeBytes { bytes in
            let base = bytes.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(bitPattern: 1)!
            var offset = 0
            let pointers = parameterSets.map { set -> UnsafePointer<UInt8> in
                defer { offset += set.count }
                return base + offset
            }
            let sizes = parameterSets.map(\.count)
            return pointers.withUnsafeBufferPointer { pointers in
                sizes.withUnsafeBufferPointer { sizes in body(pointers, sizes) }
            }
        }
    }
}

public extension CMFormatDescription {
    /// The value of the extension `key`.
    func extensionValue(for key: CFString) -> Any? {
        CMFormatDescriptionGetExtension(self, extensionKey: key)
    }
}
