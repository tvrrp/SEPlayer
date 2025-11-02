//
//  FixedTrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

import Foundation.NSUUID

struct FixedTrackSelection: SETrackSelection {
    let id = UUID()
    let trackGroup: TrackGroup
    let selectedReason: TrackSelectionReason = .unknown
    let selectedIndex: Int = 0
    var selectedFormat: Format { trackGroup.formats[selectedIndex] }
}
