//
//  FixedTrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

final class FixedTrackSelection: BaseTrackSelection {
    override var selectedReason: TrackSelectionReason { _selectedReason }
    override var selectionData: Any? { data }
    override var selectedIndex: Int { 0 }

    private let _selectedReason: TrackSelectionReason
    private let data: Any?

    init(
        group: TrackGroup,
        track: Int,
        type: TrackSelectionType = .unset,
        reason: TrackSelectionReason = .unknown,
        data: Any? = nil
    ) {
        _selectedReason = reason
        self.data = data
        super.init(group: group, tracks: [track], type: type)
    }
}
