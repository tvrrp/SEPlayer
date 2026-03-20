//
//  BaseTrackSelection.swift
//  SEPlayer
//
//  Created by tvrrp on 19.02.2026.
//

import CoreMedia
import Dispatch
import SEPlayerCommon

class BaseTrackSelection: SETrackSelection, Hashable {
    let trackGroup: TrackGroup
    let length: Int
    let tracks: [Int?]
    let type: TrackSelectionType
    let formats: [Format]

    var selectedFormat: Format { formats[selectedIndex] }
    var selectedIndexInTrackGroup: Int? { tracks[selectedIndex] }
    var selectedIndex: Int { fatalError() }
    var selectedReason: TrackSelectionReason { fatalError() }
    var selectionData: Any? { fatalError() }

    private(set) var playWhenReady: Bool
    private var excludeUntilTimes: [CMTime]

    init(group: TrackGroup, tracks: [Int], type: TrackSelectionType = .unset) {
        precondition(!tracks.isEmpty)
        self.trackGroup = group
        self.length = tracks.count
        self.type = type
        formats = tracks
            .map { group.getFormat(index: $0) }
            .sorted(by: { $0.bitrate > $1.bitrate })
        var tracks = [Int?]()
        for index in 0..<length {
            tracks.append(group.indexOf(format: formats[index]))
        }
        self.tracks = tracks
        excludeUntilTimes = Array(repeating: .zero, count: length)
        playWhenReady = false
    }

    func format(for index: Int) -> Format {
        formats[index]
    }

    func indexInTrackGroup(_ index: Int) -> Int? {
        tracks[index]
    }

    func indexOf(format: Format) -> Int? {
        formats.firstIndex(where: { $0 == format })
    }

    func indexOf(indexInTrackGroup: Int) -> Int? {
        tracks.firstIndex(where: { $0 == indexInTrackGroup })
    }

    func enable() {}
    func disable() {}
    func playbackSpeedDidChange(_ playbackSpeed: Float) {}

    func updateSelectedTrack(
        playbackPosition: CMTime,
        bufferedDuration: CMTime,
        availableDuration: CMTime,
        queue: [MediaChunk],
        mediaChunkIterators: [MediaChunkIterator]
    ) {
        fatalError()
    }

    func evaluateQueueSize(playbackPosition: CMTime, queue: [MediaChunk]) -> Int {
        queue.count
    }

    func excludeTrack(index: Int, exclusionDuration: CMTime) -> Bool {
        let now = CMClock.hostTimeClock.time
        var canExclude = !isTrackExcluded(index: index, now: now)
        for i in 0..<length where i != index {
            if !isTrackExcluded(index: i, now: now) {
                canExclude = true
            }
        }

        if !canExclude { return false }

        let excludeUntil = now + exclusionDuration
        if excludeUntil.isValid {
            excludeUntilTimes[index] = max(excludeUntilTimes[index], excludeUntil)
        } else {
            excludeUntilTimes[index] = .positiveInfinity
        }

        return true
    }

    func isTrackExcluded(index: Int, now: CMTime) -> Bool {
        excludeUntilTimes[index] > now
    }

    func playWhenReadyChanged(_ playWhenReady: Bool) {
        self.playWhenReady = playWhenReady
    }

    func isEquals(to other: SETrackSelection) -> Bool {
        guard let other = other as? BaseTrackSelection else {
            return false
        }

        return trackGroup == other.trackGroup && tracks == other.tracks
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(trackGroup)
        hasher.combine(tracks)
    }
}

extension BaseTrackSelection: Equatable {
    static func == (lhs: BaseTrackSelection, rhs: BaseTrackSelection) -> Bool {
        lhs.isEquals(to: rhs)
    }
}
