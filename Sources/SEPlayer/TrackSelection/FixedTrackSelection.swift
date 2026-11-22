//
//  FixedTrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.trackselection.FixedTrackSelection
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

/// An ``SETrackSelection`` of one track, which never changes.
public final class FixedTrackSelection: BaseTrackSelection {
    public override var selectedReason: TrackSelectionReason { _selectedReason }
    public override var selectionData: Any? { data }
    public override var selectedIndex: Int { 0 }

    private let _selectedReason: TrackSelectionReason
    private let data: Any?

    public init(
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

    public override func updateSelectedTrack(
        playbackPosition: CMTime,
        bufferedDuration: CMTime,
        availableDuration: CMTime,
        queue: [MediaChunk],
        mediaChunkIterators: [MediaChunkIterator]
    ) {
        // nop
    }
}
