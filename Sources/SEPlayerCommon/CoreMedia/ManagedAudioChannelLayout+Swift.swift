//
//  ManagedAudioChannelLayout+Swift.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import CoreAudio

public extension ManagedAudioChannelLayout {
    /// The size of a layout without channel descriptions: the tag, the bitmap and the number of descriptions.
    static let headerSize = 12
    /// The size of each channel description after the header.
    static let channelDescriptionSize = 20

    /// A copy of the `AudioChannelLayout` in `bytes`, in host byte order, as the audio format services give layouts.
    ///
    /// - Returns: `nil` for fewer bytes than a layout without descriptions, or than its descriptions need.
    init?(layoutBytes bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= Self.headerSize else { return nil }
        let descriptionCount = Int(bytes.load(fromByteOffset: 8, as: UInt32.self))
        guard bytes.count >= Self.headerSize + descriptionCount * Self.channelDescriptionSize else {
            return nil
        }
        self.init(copying: bytes, size: Self.headerSize + descriptionCount * Self.channelDescriptionSize)
    }

    /// The `AudioChannelLayout` in `bytes` whose fields are big-endian, as files store layouts.
    ///
    /// Descriptions that don't fit in `bytes` are dropped, leaving the layout its tag; a layout made of its
    /// descriptions alone then can't be read.
    ///
    /// - Returns: `nil` for fewer bytes than a layout without descriptions, or a layout of descriptions that don't fit.
    init?<Bytes: RandomAccessCollection<UInt8>>(bigEndianLayoutBytes bytes: Bytes) where Bytes.Index == Int {
        guard bytes.count >= Self.headerSize else { return nil }
        let start = bytes.startIndex
        func field(_ offset: Int) -> UInt32 {
            (0 ..< 4).reduce(0) { $0 << 8 | UInt32(bytes[start + offset + $1]) }
        }
        let tag = field(0)
        var descriptionCount = Int(field(8))
        if (bytes.count / 4 * 4 - Self.headerSize) / Self.channelDescriptionSize < descriptionCount {
            guard tag != kAudioChannelLayoutTag_UseChannelDescriptions else {
                return nil
            }
            descriptionCount = 0
        }

        let size = Self.headerSize + descriptionCount * Self.channelDescriptionSize
        let fields = (0 ..< (size / 4)).map { index in index == 2 ? UInt32(descriptionCount) : field(index * 4) }
        self = fields.withUnsafeBytes { Self(copying: $0, size: size) }
    }

    /// A layout of its tag alone: the layouts of `init(tag:)` have a channel description too, of no channel.
    init(layoutTag tag: AudioChannelLayoutTag) {
        self = [tag, 0, 0].withUnsafeBytes { Self(copying: $0, size: Self.headerSize) }
    }

    /// A layout that names each channel.
    init(labels: [AudioChannelLabel]) {
        self.init(channelDescriptions: labels.map {
            AudioChannelDescription(mChannelLabel: $0, mChannelFlags: [], mCoordinates: (0, 0, 0))
        })
    }

    /// Calls `body` with the layout and its size in bytes: the header and its channel descriptions.
    ///
    /// The size is the layout's own, as a layout copied from a pointer has no other record of it.
    func withUnsafeLayout<R>(_ body: (UnsafePointer<AudioChannelLayout>, Int) throws -> R) rethrows -> R {
        try withUnsafePointer { layout in
            let size = Self.headerSize + Int(layout.pointee.mNumberChannelDescriptions) * Self.channelDescriptionSize
            return try body(layout, size)
        }
    }

    /// The number of channels the layout describes: by its tag, the bits of its bitmap, or its descriptions.
    var describedChannelCount: Int {
        switch tag {
        case kAudioChannelLayoutTag_UseChannelDescriptions: channelDescriptions.count
        case kAudioChannelLayoutTag_UseChannelBitmap: bitmap.rawValue.nonzeroBitCount
        default: Int(tag & 0xFFFF)
        }
    }

    private init(copying bytes: UnsafeRawBufferPointer, size: Int) {
        let capacity = max(size, MemoryLayout<AudioChannelLayout>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        raw.copyMemory(from: bytes.baseAddress!, byteCount: size)
        let layout = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        self.init(audioChannelLayoutPointer: .init(layout), deallocator: { _ in raw.deallocate() })
    }
}
