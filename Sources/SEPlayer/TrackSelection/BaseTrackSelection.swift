//
//  BaseTrackSelection.swift
//  SEPlayer
//
//  Created by tvrrp on 19.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.trackselection.BaseTrackSelection
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Dispatch
import SEPlayerCommon

/// The part ``SETrackSelection`` implementations share: the tracks of a group from the highest bitrate down, and the
/// tracks excluded for a while.
///
/// Subclasses provide the selected index, reason and data, and update the selection in
/// ``updateSelectedTrack(playbackPosition:bufferedDuration:availableDuration:queue:mediaChunkIterators:)``.
open class BaseTrackSelection: SETrackSelection, Hashable {
    public let trackGroup: TrackGroup
    public let length: Int
    public let tracks: [Int?]
    public let type: TrackSelectionType
    public let formats: [AnyFormat]

    public final var selectedFormat: AnyFormat { formats[selectedIndex] }
    public final var selectedIndexInTrackGroup: Int? { tracks[selectedIndex] }
    open var selectedIndex: Int { fatalError("To override") }
    open var selectedReason: TrackSelectionReason { fatalError("To override") }
    open var selectionData: Any? { fatalError("To override") }

    open var measuredBitrate: Int? {
        guard let loaded = loadedMedia[selectedIndex], loaded.seconds > 0 else {
            return nil
        }
        return Int(loaded.bits / loaded.seconds)
    }

    public private(set) var playWhenReady: Bool
    private var excludeUntilTimes: [CMTime]
    /// The bits and seconds of the loaded chunks of formats without a bitrate, by index.
    private var loadedMedia: [Int: (bits: Double, seconds: Double)] = [:]

    public init(group: TrackGroup, tracks: [Int], type: TrackSelectionType = .unset) {
        precondition(!tracks.isEmpty)
        self.trackGroup = group
        self.length = tracks.count
        self.type = type
        formats = tracks
            .map { group.getFormat(index: $0) }
            .sorted(by: { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) })
        var tracks = [Int?]()
        for index in 0 ..< length {
            tracks.append(group.indexOf(format: formats[index]))
        }
        self.tracks = tracks
        excludeUntilTimes = Array(repeating: .zero, count: length)
        playWhenReady = false
    }

    public final func format(for index: Int) -> AnyFormat {
        formats[index]
    }

    public final func indexInTrackGroup(_ index: Int) -> Int? {
        tracks[index]
    }

    public final func indexOf(format: AnyFormat) -> Int? {
        formats.firstIndex(where: { $0 == format })
    }

    public final func indexOf(indexInTrackGroup: Int) -> Int? {
        tracks.firstIndex(where: { $0 == indexInTrackGroup })
    }

    open func enable() {}
    open func disable() {}
    open func playbackSpeedDidChange(_ playbackSpeed: Float) {}
    open func loadsQuickly(bits: Double) -> Bool? { nil }

    open func updateSelectedTrack(
        playbackPosition: CMTime,
        bufferedDuration: CMTime,
        availableDuration: CMTime,
        queue: [MediaChunk],
        mediaChunkIterators: [MediaChunkIterator]
    ) {
        fatalError("To override")
    }

    open func evaluateQueueSize(playbackPosition: CMTime, queue: [MediaChunk]) -> Int {
        queue.count
    }

    public final func excludeTrack(index: Int, exclusionDuration: CMTime) -> Bool {
        let now = CMClock.hostTimeClock.time
        // An excluded track can stay excluded for longer; otherwise another track has to be left to play.
        let canExclude = isTrackExcluded(index: index, now: now)
            || (0 ..< length).contains { $0 != index && !isTrackExcluded(index: $0, now: now) }

        if !canExclude { return false }

        let excludeUntil = now + exclusionDuration
        if excludeUntil.isValid {
            excludeUntilTimes[index] = max(excludeUntilTimes[index], excludeUntil)
        } else {
            excludeUntilTimes[index] = .positiveInfinity
        }

        return true
    }

    public final func isTrackExcluded(index: Int, now: CMTime) -> Bool {
        excludeUntilTimes[index] > now
    }

    open func chunkLoaded(_ chunk: MediaChunk) {
        guard let format = chunk.trackFormat, format.bitrate == nil, let index = indexOf(format: format),
              chunk.endTime.isNumeric, chunk.startTime.isNumeric, chunk.endTime > chunk.startTime,
              chunk.bytesLoaded > 0 else {
            return
        }
        var loaded = loadedMedia[index] ?? (0, 0)
        loaded.bits += Double(chunk.bytesLoaded * 8)
        loaded.seconds += (chunk.endTime - chunk.startTime).seconds
        loadedMedia[index] = loaded
    }

    open func playWhenReadyChanged(_ playWhenReady: Bool) {
        self.playWhenReady = playWhenReady
    }

    public final func isEquals(to other: SETrackSelection) -> Bool {
        guard let other = other as? BaseTrackSelection else {
            return false
        }

        return trackGroup == other.trackGroup && tracks == other.tracks
    }

    public final func hash(into hasher: inout Hasher) {
        hasher.combine(trackGroup)
        hasher.combine(tracks)
    }
}

extension BaseTrackSelection: Equatable {
    public static func == (lhs: BaseTrackSelection, rhs: BaseTrackSelection) -> Bool {
        lhs.isEquals(to: rhs)
    }
}
