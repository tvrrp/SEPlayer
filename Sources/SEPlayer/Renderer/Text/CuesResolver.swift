//
//  CuesResolver.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//

import CoreMedia
import Extractor
import SEPlayerCommon

/// A `CuesResolver` maps from time to the subtitle cues that should be shown.
///
/// It also exposes methods for querying when the next and previous change in subtitles is.
///
/// Different implementations may provide different resolution algorithms.
protocol CuesResolver {
    /// Adds `cues` to this instance, returning whether this changes the cues displayed at `currentPosition`.
    func addCues(_ cues: CuesWithTiming, currentPosition: CMTime) throws -> Bool

    /// Returns the cues that should be shown at time `time`.
    ///
    /// - Parameter time: The time to query.
    /// - Returns: The cues that should be shown, ordered by ascending priority for compatibility with `CueGroup.cues`.
    func getCues(at time: CMTime) -> [Cue]

    /// Discards all cues that won't be shown at or after `time`.
    ///
    /// - Parameter time: The time to discard cues before.
    func discardCues(before time: CMTime)

    /// Returns the time of the change in cue output at or before `time`.
    ///
    /// If there's no change before `time`, returns `nil`.
    func getPreviousCueChangeTime(_ time: CMTime) -> CMTime?

    /// Returns the time of the next change in cue output after `time` (exclusive).
    ///
    /// If there's no change after `time`, returns `nil`.
    func getNextCueChangeTime(_ time: CMTime) -> CMTime?

    /// Clears all cues that have been added to this instance.
    func clear()
}

/// A `CuesResolver` which resolves each time to at most one `CuesWithTiming` instance.
///
/// Each `CuesWithTiming` is used from its start time to its end time, or the start time of the next instance if
/// sooner (or the end time is `.invalid`).
///
/// If the last `CuesWithTiming` has an unset end time, its used until the end of the playback.
final class ReplacingCuesResolver: CuesResolver {
    /// Sorted by `CuesWithTiming.startTime` ascending.
    private var cuesWithTimingList: [CuesWithTiming] = []

    func addCues(_ cues: CuesWithTiming, currentPosition: CMTime) throws -> Bool {
        try checkArgument(cues.startTime.isValid)
        var cuesAreShownAtCurrentTime = cues.startTime <= currentPosition
            && (!cues.endTime.isValid || currentPosition < cues.endTime)

        for index in cuesWithTimingList.indices.reversed() {
            if cues.startTime >= cuesWithTimingList[index].startTime {
                cuesWithTimingList.insert(cues, at: index + 1)
                return cuesAreShownAtCurrentTime
            } else if cuesWithTimingList[index].startTime <= currentPosition {
                // There's a cue that starts after the new cues, but before the current time, meaning the new cues will
                // not be displayed at the current time.
                cuesAreShownAtCurrentTime = false
            }
        }

        cuesWithTimingList.insert(cues, at: 0)
        return cuesAreShownAtCurrentTime
    }

    func getCues(at time: CMTime) -> [Cue] {
        let indexStartingAfterTime = getIndexOfCuesStarting(after: time)
        if indexStartingAfterTime == 0 {
            // Either the first cue starts after time, or the cues list is empty.
            return []
        }

        let cues = cuesWithTimingList[indexStartingAfterTime - 1]
        return !cues.endTime.isValid || time < cues.endTime ? cues.cues : []
    }

    func discardCues(before time: CMTime) {
        var indexToDiscardTo = getIndexOfCuesStarting(after: time)
        if indexToDiscardTo == 0 {
            // Either the first cue starts after time, or the cues list is empty.
            return
        }

        let lastCueToDiscard = cuesWithTimingList[indexToDiscardTo - 1]
        if !lastCueToDiscard.endTime.isValid || lastCueToDiscard.endTime >= time {
            indexToDiscardTo -= 1
        }
        cuesWithTimingList.removeSubrange(0 ..< indexToDiscardTo)
    }

    func getPreviousCueChangeTime(_ time: CMTime) -> CMTime? {
        guard let first = cuesWithTimingList.first, time >= first.startTime else {
            return nil
        }

        for index in cuesWithTimingList.indices.dropFirst() {
            let nextCuesStartTime = cuesWithTimingList[index].startTime
            if time == nextCuesStartTime {
                return nextCuesStartTime
            }
            if time < nextCuesStartTime {
                let cues = cuesWithTimingList[index - 1]
                return cues.endTime.isValid && cues.endTime <= time ? cues.endTime : cues.startTime
            }
        }

        let lastCues = cuesWithTimingList[cuesWithTimingList.count - 1]
        return !lastCues.endTime.isValid || time < lastCues.endTime ? lastCues.startTime : lastCues.endTime
    }

    func getNextCueChangeTime(_ time: CMTime) -> CMTime? {
        guard let first = cuesWithTimingList.first else {
            return nil
        }
        if time < first.startTime {
            return first.startTime
        }

        for index in cuesWithTimingList.indices.dropFirst() {
            let cues = cuesWithTimingList[index]
            if time < cues.startTime {
                let previousCues = cuesWithTimingList[index - 1]
                return previousCues.endTime.isValid
                    && previousCues.endTime > time
                    && previousCues.endTime < cues.startTime
                    ? previousCues.endTime
                    : cues.startTime
            }
        }

        let lastCues = cuesWithTimingList[cuesWithTimingList.count - 1]
        return lastCues.endTime.isValid && time < lastCues.endTime ? lastCues.endTime : nil
    }

    func clear() {
        cuesWithTimingList.removeAll()
    }

    /// Returns the index of the first `CuesWithTiming` in `cuesWithTimingList` where `CuesWithTiming.startTime` is
    /// strictly greater than `time`.
    ///
    /// Returns the size of `cuesWithTimingList` if all cues are before time.
    private func getIndexOfCuesStarting(after time: CMTime) -> Int {
        cuesWithTimingList.firstIndex { time < $0.startTime } ?? cuesWithTimingList.count
    }
}

/// A `CuesResolver` which merges possibly-overlapping `CuesWithTiming` instances.
///
/// This implementation only accepts with `CuesWithTiming` with a set `CuesWithTiming.duration`.
final class MergingCuesResolver: CuesResolver {
    /// Sorted by `CuesWithTiming.startTime` ascending.
    private var cuesWithTimingList: [CuesWithTiming] = []

    func addCues(_ cues: CuesWithTiming, currentPosition: CMTime) throws -> Bool {
        try checkArgument(cues.startTime.isValid)
        try checkArgument(cues.duration.isValid)
        let cuesAreShownAtCurrentTime = cues.startTime <= currentPosition && currentPosition < cues.endTime

        for index in cuesWithTimingList.indices.reversed() where cues.startTime >= cuesWithTimingList[index].startTime {
            cuesWithTimingList.insert(cues, at: index + 1)
            return cuesAreShownAtCurrentTime
        }

        cuesWithTimingList.insert(cues, at: 0)
        return cuesAreShownAtCurrentTime
    }

    func getCues(at time: CMTime) -> [Cue] {
        guard let first = cuesWithTimingList.first, time >= first.startTime else {
            return []
        }

        var visibleCues: [CuesWithTiming] = []
        for cues in cuesWithTimingList {
            if time >= cues.startTime && time < cues.endTime {
                visibleCues.append(cues)
            }
            if time < cues.startTime {
                break
            }
        }

        // Sorts in ascending display priority, for compatibility with the ordering defined for `CueGroup.cues`: first
        // by start time ascending (later cues should be shown on top of older ones), then by duration descending
        // (shorter duration cues that start at the same time should be shown on top, as the one underneath will be
        // visible after they disappear).
        return visibleCues
            .sorted { lhs, rhs in
                lhs.startTime != rhs.startTime ? lhs.startTime < rhs.startTime : lhs.duration > rhs.duration
            }
            .flatMap(\.cues)
    }

    func discardCues(before time: CMTime) {
        var index = 0
        while index < cuesWithTimingList.count {
            let startTime = cuesWithTimingList[index].startTime
            if time > startTime && time > cuesWithTimingList[index].endTime {
                // In most cases only a single item will be removed in each invocation of this method, so the
                // inefficiency of removing items one-by-one inside a loop is mitigated.
                cuesWithTimingList.remove(at: index)
            } else if time < startTime {
                break
            } else {
                index += 1
            }
        }
    }

    func getPreviousCueChangeTime(_ time: CMTime) -> CMTime? {
        guard let first = cuesWithTimingList.first, time >= first.startTime else {
            return nil
        }

        var result = first.startTime
        for cues in cuesWithTimingList {
            if cues.endTime <= time {
                result = max(result, cues.endTime)
            } else if cues.startTime <= time {
                result = max(result, cues.startTime)
            } else {
                break
            }
        }
        return result
    }

    func getNextCueChangeTime(_ time: CMTime) -> CMTime? {
        var result: CMTime?
        for cues in cuesWithTimingList {
            if time < cues.startTime {
                result = result.map { min($0, cues.startTime) } ?? cues.startTime
                break
            } else if time < cues.endTime {
                result = result.map { min($0, cues.endTime) } ?? cues.endTime
            }
        }
        return result
    }

    func clear() {
        cuesWithTimingList.removeAll()
    }
}
