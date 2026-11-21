//
//  TrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import SEPlayerCommon

@frozen
public enum TrackSelectionType {
    case unset
    case customBase
}

public protocol TrackSelection {
    var type: TrackSelectionType { get }
    var trackGroup: TrackGroup { get }
    var length: Int { get }

    func format(for index: Int) -> AnyFormat
    func indexInTrackGroup(_ index: Int) -> Int?
    func indexOf(format: AnyFormat) -> Int?
    func indexOf(indexInTrackGroup: Int) -> Int?
}

extension TrackSelection {
    func format(for index: Int) -> AnyFormat {
        trackGroup[index]
    }
}
