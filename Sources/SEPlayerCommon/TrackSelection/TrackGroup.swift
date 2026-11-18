//
//  TrackGroup.swift
//  SEPlayerCommon
//
//  Created by Damir Yackupov on 06.01.2025.
//

public struct TrackGroup: Hashable, Sendable {
    public var length: Int { formats.count }
    public let id: String
    public let type: TrackType
    private let formats: [Format]

    public enum TrackGroupError: Error {
        case emptyFormats
        case differentFormatsForTrackGroup
    }

    public init(
        id: String = "",
        formats: [Format]
    ) throws(TrackGroupError) {
        guard !formats.isEmpty else { throw .emptyFormats }
        self.id = id
        self.formats = formats

        let sampleMimeType = formats[0].sampleMimeType
        self.type = if let sampleMimeType, sampleMimeType.rawValue.isEmpty {
            formats[0].containerMimeType.trackType
        } else {
            sampleMimeType.trackType
        }

        try verifyCorrectness()
    }

    public func copyWithId(_ id: String) throws(TrackGroupError) -> TrackGroup {
        try TrackGroup(id: id, formats: formats)
    }

    public func getFormat(index: Int) -> Format {
        formats[index]
    }

    public func indexOf(format: Format) -> Int? {
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
    public typealias Index = Array<Format>.Index
    public typealias Element = Format
    public var startIndex: Int { formats.startIndex }
    public var endIndex: Int { formats.endIndex }

    public subscript(index: Index) -> Iterator.Element { formats[index] }

    public func index(after i: Index) -> Index {
        formats.index(after: i)
    }
}
