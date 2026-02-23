//
//  TrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

@frozen public enum TrackSelectionType {
    case unset
    case customBase
}

public protocol TrackSelection {
    var type: TrackSelectionType { get }
    var trackGroup: TrackGroup { get }
    var length: Int { get }

    func format(for index: Int) -> Format
    func indexInTrackGroup(_ index: Int) -> Int?
    func indexOf(format: Format) -> Int?
    func indexOf(indexInTrackGroup: Int) -> Int?
}

extension TrackSelection {
    func format(for index: Int) -> Format {
        trackGroup[index]
    }
}
