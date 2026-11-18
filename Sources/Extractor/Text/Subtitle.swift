//
//  Subtitle.swift
//  SEPlayer
//

import CoreMedia
import SEPlayerCommon

/// Cues that change at event times: between two events the same cues show.
protocol Subtitle {
    /// The event times, in increasing order.
    var eventTimes: [CMTime] { get }

    /// The cues that show at `time`.
    func cues(at time: CMTime) -> [Cue]
}

extension Subtitle {
    /// The index of the first event after `time`, or `nil` if there is none.
    func nextEventTimeIndex(after time: CMTime) -> Int? {
        let index = Util.binarySearchCeil(array: eventTimes, value: time, inclusive: false, stayInBounds: false)
        return index < eventTimes.count ? index : nil
    }

    /// Emits the cues between consecutive events, as the output options ask.
    ///
    /// With a start time, the cues from it come first: those that already show at the start time, then the following
    /// events. If all cues are asked for, the events before the start time follow.
    func toCuesWithTiming(outputOptions: SubtitleParserOutputOptions, output: (CuesWithTiming) throws -> Void) throws {
        let startIndex = startIndex(outputOptions: outputOptions)
        var startedInMiddleOfCue = false
        if outputOptions.startTime.isValid, startIndex < eventTimes.count {
            let cuesAtStartTime = cues(at: outputOptions.startTime)
            let firstEventTime = eventTimes[startIndex]
            if !cuesAtStartTime.isEmpty, outputOptions.startTime < firstEventTime {
                try output(CuesWithTiming(
                    cues: cuesAtStartTime,
                    startTime: outputOptions.startTime,
                    duration: firstEventTime - outputOptions.startTime
                ))
                startedInMiddleOfCue = true
            }
        }

        for index in startIndex..<eventTimes.count {
            try outputEvent(at: index, output: output)
        }

        guard outputOptions.outputAllCues else { return }
        let endIndex = startedInMiddleOfCue ? startIndex - 1 : startIndex
        for index in 0..<max(0, endIndex) {
            try outputEvent(at: index, output: output)
        }
        if startedInMiddleOfCue, endIndex >= 0 {
            let eventTime = eventTimes[endIndex]
            try output(CuesWithTiming(
                cues: cues(at: eventTime),
                startTime: eventTime,
                duration: outputOptions.startTime - eventTime
            ))
        }
    }

    private func startIndex(outputOptions: SubtitleParserOutputOptions) -> Int {
        guard outputOptions.startTime.isValid else { return 0 }
        guard let index = nextEventTimeIndex(after: outputOptions.startTime) else {
            return eventTimes.count
        }
        if index > 0, eventTimes[index - 1] == outputOptions.startTime {
            return index - 1
        }
        return index
    }

    private func outputEvent(at index: Int, output: (CuesWithTiming) throws -> Void) throws {
        let startTime = eventTimes[index]
        let cues = cues(at: startTime)
        // No cues show until the next event, or it is the last event, where all cues end.
        guard !cues.isEmpty, index + 1 < eventTimes.count else { return }
        let duration = eventTimes[index + 1] - startTime
        if duration > .zero {
            try output(CuesWithTiming(cues: cues, startTime: startTime, duration: duration))
        }
    }
}
