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
    var selectedIndex: Int { fatalError("To override") }
    var selectedReason: TrackSelectionReason { fatalError("To override") }
    var selectionData: Any? { fatalError("To override") }

    var measuredBitrate: Int? {
        guard let loaded = loadedMedia[selectedIndex], loaded.seconds > 0 else {
            return nil
        }
        return Int(loaded.bits / loaded.seconds)
    }

    private(set) var playWhenReady: Bool
    private var excludeUntilTimes: [CMTime]
    /// The bits and seconds of the loaded chunks of formats without a bitrate, by index.
    private var loadedMedia: [Int: (bits: Double, seconds: Double)] = [:]

    init(group: TrackGroup, tracks: [Int], type: TrackSelectionType = .unset) {
        precondition(!tracks.isEmpty)
        self.trackGroup = group
        self.length = tracks.count
        self.type = type
        formats = tracks
            .map { group.getFormat(index: $0) }
            .sorted(by: { $0.bitrate > $1.bitrate })
        var tracks = [Int?]()
        for index in 0 ..< length {
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
    func loadsQuickly(bits: Double) -> Bool? { nil }

    func updateSelectedTrack(
        playbackPosition: CMTime,
        bufferedDuration: CMTime,
        availableDuration: CMTime,
        queue: [MediaChunk],
        mediaChunkIterators: [MediaChunkIterator]
    ) {
        fatalError("To override")
    }

    func evaluateQueueSize(playbackPosition: CMTime, queue: [MediaChunk]) -> Int {
        queue.count
    }

    func excludeTrack(index: Int, exclusionDuration: CMTime) -> Bool {
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

    func isTrackExcluded(index: Int, now: CMTime) -> Bool {
        excludeUntilTimes[index] > now
    }

    func chunkLoaded(_ chunk: MediaChunk) {
        guard let format = chunk.trackFormat, format.bitrate == Format.noValue, let index = indexOf(format: format),
              chunk.endTime.isNumeric, chunk.startTime.isNumeric, chunk.endTime > chunk.startTime,
              chunk.bytesLoaded > 0 else {
            return
        }
        var loaded = loadedMedia[index] ?? (0, 0)
        loaded.bits += Double(chunk.bytesLoaded * 8)
        loaded.seconds += (chunk.endTime - chunk.startTime).seconds
        loadedMedia[index] = loaded
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
