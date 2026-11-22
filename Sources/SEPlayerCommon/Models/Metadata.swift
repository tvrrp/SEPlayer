//
//  Metadata.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.Metadata
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation

/// A list of metadata entries: the tags of a container or a stream, or the content of a timed metadata sample.
public struct Metadata: Sendable {
    /// One piece of metadata, such as an ID3 frame or an MP4 tag.
    public protocol Entry: Hashable, Sendable, CustomStringConvertible {
        /// The format of the metadata this entry wraps, if it carries another metadata format: an ID3 tag in an
        /// `emsg` box, say.
        var wrappedMetadataFormat: MetadataFormat? { get }
        /// The metadata this entry wraps, when ``wrappedMetadataFormat`` isn't `nil`.
        var wrappedMetadataData: Data? { get }
        /// Sets the fields of `builder` that this entry describes.
        func populateMediaMetadata(_ builder: MediaMetadata.Builder)
    }

    /// When the metadata applies, for metadata of a timed stream; `.invalid` for static metadata.
    public let presentationTime: CMTime
    public let entries: [any Entry]

    public init(presentationTime: CMTime = .invalid, entries: [any Entry] = []) {
        self.presentationTime = presentationTime
        self.entries = entries
    }

    public init(presentationTime: CMTime = .invalid, _ entries: any Entry...) {
        self.init(presentationTime: presentationTime, entries: entries)
    }

    /// This metadata with the entries of `other` after its own.
    public func appending(_ other: Metadata?) -> Metadata {
        guard let other else { return self }
        return appending(other.entries)
    }

    /// This metadata with `entries` after its own.
    public func appending(_ entries: [any Entry]) -> Metadata {
        guard !entries.isEmpty else { return self }
        return Metadata(presentationTime: presentationTime, entries: self.entries + entries)
    }

    public func withPresentationTime(_ presentationTime: CMTime) -> Metadata {
        Metadata(presentationTime: presentationTime, entries: entries)
    }

    /// The first entry of type `T`.
    public func first<T: Entry>(of type: T.Type) -> T? {
        entries.lazy.compactMap { $0 as? T }.first
    }
}

extension Metadata: Hashable {
    public static func == (lhs: Metadata, rhs: Metadata) -> Bool {
        lhs.presentationTime == rhs.presentationTime
            && lhs.entries.map { AnyHashable($0) } == rhs.entries.map { AnyHashable($0) }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(presentationTime)
        entries.forEach { hasher.combine(AnyHashable($0)) }
    }
}

extension Metadata: RandomAccessCollection {
    public var startIndex: Int { entries.startIndex }
    public var endIndex: Int { entries.endIndex }

    public subscript(index: Int) -> any Entry { entries[index] }
}

extension Metadata: CustomStringConvertible {
    public var description: String {
        let entries = entries.map(\.description).joined(separator: ", ")
        guard presentationTime.isValid else { return "entries=[\(entries)]" }
        return "entries=[\(entries)], time=\(presentationTime.seconds)"
    }
}

public extension Metadata.Entry {
    var wrappedMetadataFormat: MetadataFormat? { nil }
    var wrappedMetadataData: Data? { nil }
    func populateMediaMetadata(_ builder: MediaMetadata.Builder) {}
}
