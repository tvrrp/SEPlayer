//
//  AudioQueuePositionTracker.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.04.2025.
//

import AudioToolbox
import CoreMedia.CMSync

final class AudioQueuePositionTracker {
    private let clock: CMClock
    private var audioQueue: AudioQueueRef?
    private var audioTimeline: AudioQueueTimelineRef?
    private var outputFormat: AudioStreamBasicDescription?

    private var playbackRate: Float = 1.0
    private var rawPlaybackHeadPosition: Int64 = 0
    private var stopTimestamp: Int64? = nil
    private var stopPlaybackHeadPosition: Int64 = 0
    private var endPlaybackHeadPosition: Int64 = 0

    private var forceResetWorkaroundTime: Int64?
    private var isPlaying = false

    init(clock: CMClock) {
        self.clock = clock
    }

    func setAudioQueue(_ audioQueue: AudioQueueRef, outputFormat: AudioStreamBasicDescription) {
        self.audioQueue = audioQueue
        self.outputFormat = outputFormat
        rawPlaybackHeadPosition = 0
        stopTimestamp = nil
        playbackRate = 1.0
        forceResetWorkaroundTime = nil

        AudioQueueCreateTimeline(audioQueue, &audioTimeline)
    }

    func setPlaybackSpeed(new playbackRate: Float) {
        self.playbackRate = playbackRate
    }

    func getCurrentPosition() -> Int64 {
        guard let outputFormat else { return 0 }
        let rawPosition = getPlaybackHeadPosition()

        return AudioUtils.sampleCountToDuration(
            sampleCount: rawPosition,
            sampleRate: outputFormat.mSampleRate
        )
    }

    func start() {
        isPlaying = true
        forceResetWorkaroundTime = nil
        if stopTimestamp != nil {
            stopTimestamp = clock.microseconds
        }
    }

    func didReleaseAudioQueueBuffer() {
        forceResetWorkaroundTime = clock.microseconds
    }

    func isStalled(writtenFrames: Int64) -> Bool {
        guard let forceResetWorkaroundTime, isPlaying else { return false }
        return clock.microseconds - forceResetWorkaroundTime > 2 * Int64.microsecondsPerSecond
    }

    func handleEndOfStream(writtenFrames: Int64) {
        stopPlaybackHeadPosition = getPlaybackHeadPosition()
        stopTimestamp = clock.microseconds
        endPlaybackHeadPosition = writtenFrames
        forceResetWorkaroundTime = nil
    }

    func hasPendingData(writtenFrames: Int64) -> Bool {
        guard let outputFormat else { return false }
        return writtenFrames > AudioUtils.durationToSampleCount(
            duration: getCurrentPosition(),
            sampleRate: outputFormat.mSampleRate
        )
    }

    func pause() -> Bool {
        isPlaying = false
        forceResetWorkaroundTime = nil
        if stopTimestamp == nil {
            return true
        }
        stopPlaybackHeadPosition = getPlaybackHeadPosition()
        return false
    }

    func reset() {
        audioQueue = nil
        outputFormat = nil
        forceResetWorkaroundTime = nil
    }

    private func getPlaybackHeadPosition() -> Int64 {
        if let stopTimestamp {
            let simulatedPlaybackHeadPosition = simulatedPlaybackHeadPositionAfterStop(stopTimestamp: stopTimestamp)
            return min(endPlaybackHeadPosition, simulatedPlaybackHeadPosition)
        }

        updateRawPlaybackHeadPosition()
        return rawPlaybackHeadPosition
    }

    private func simulatedPlaybackHeadPositionAfterStop(stopTimestamp: Int64) -> Int64 {
        guard let outputFormat else { return 0 }
        if !isPlaying {
            return stopPlaybackHeadPosition
        }
        let elapsedTimeSinceStop = clock.microseconds - stopTimestamp
        let mediaTimeSinceStop = AudioUtils.mediaDurationFor(playoutDuration: elapsedTimeSinceStop, speed: playbackRate)
        let framesSinceStop = AudioUtils.durationToSampleCount(duration: mediaTimeSinceStop, sampleRate: outputFormat.mSampleRate)
        return stopPlaybackHeadPosition + framesSinceStop
    }

    private func updateRawPlaybackHeadPosition() {
        guard let audioQueue, isPlaying else { return }
        var timestamp = AudioTimeStamp()

        AudioQueueGetCurrentTime(audioQueue, audioTimeline, &timestamp, nil)
        self.rawPlaybackHeadPosition = Int64(timestamp.mSampleTime)
    }
}
