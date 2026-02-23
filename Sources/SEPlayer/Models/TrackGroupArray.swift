//
//  TrackGroupArray.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//

public struct TrackGroupArray: Hashable {
    public static let empty = TrackGroupArray(trackGroups: [])
    private let trackGroups: [TrackGroup]

    public init(trackGroups: [TrackGroup]) {
        self.trackGroups = trackGroups
    }
}

extension TrackGroupArray: Collection {
    public typealias Index = Array<TrackGroup>.Index
    public typealias Element = TrackGroup
    public var startIndex: Int { trackGroups.startIndex }
    public var endIndex: Int { trackGroups.endIndex }

    public subscript(index: Index) -> Iterator.Element {
        get { return trackGroups[index] }
    }

    public func index(after i: Index) -> Index {
        return trackGroups.index(after: i)
    }
}
