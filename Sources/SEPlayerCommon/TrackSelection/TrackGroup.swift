//
//  TrackGroup.swift
//  SEPlayerCommon
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.TrackGroup
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

public struct TrackGroup: Hashable, Sendable {
    public var length: Int { formats.count }
    public let id: String
    public let type: TrackType
    private let formats: [AnyFormat]

    public enum TrackGroupError: Error {
        case emptyFormats
        case differentFormatsForTrackGroup
    }

    public init(
        id: String = "",
        formats: [AnyFormat]
    ) throws(TrackGroupError) {
        guard !formats.isEmpty else { throw .emptyFormats }
        self.id = id
        self.formats = formats
        self.type = formats[0].trackType

        try verifyCorrectness()
    }

    public func copyWithId(_ id: String) throws(TrackGroupError) -> TrackGroup {
        try TrackGroup(id: id, formats: formats)
    }

    public func getFormat(index: Int) -> AnyFormat {
        formats[index]
    }

    public func indexOf(format: AnyFormat) -> Int? {
        formats.firstIndex(of: format)
    }

    private func verifyCorrectness() throws(TrackGroupError) {
        // TODO: verifyCorrectness
    }

    public static func == (lhs: TrackGroup, rhs: TrackGroup) -> Bool {
        lhs.id == rhs.id && lhs.formats == rhs.formats
    }
}

extension TrackGroup: Collection {
    public typealias Index = Array<AnyFormat>.Index
    public typealias Element = AnyFormat
    public var startIndex: Int { formats.startIndex }
    public var endIndex: Int { formats.endIndex }

    public subscript(index: Index) -> Iterator.Element { formats[index] }

    public func index(after i: Index) -> Index {
        formats.index(after: i)
    }
}
