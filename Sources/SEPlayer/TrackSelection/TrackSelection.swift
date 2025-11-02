//
//  TrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

public protocol TrackSelection {
    var trackGroup: TrackGroup { get }
}

extension TrackSelection {
    func format(for index: Int) -> Format {
        trackGroup.formats[index]
    }
}
