//
//  TrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia.CMFormatDescription

public protocol TrackSelection {
    var trackGroup: TrackGroup { get }
}

extension TrackSelection {
    func format(for index: Int) -> CMFormatDescription {
        trackGroup.formats[index]
    }
}
