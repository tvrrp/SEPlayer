//
//  AudioPositionTracker.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.03.2025.
//

import AudioToolbox
import CoreMedia

final class AudioPositionTracker {
    private let queue: Queue
    private let clock: CMClock
    private let outputSampleRate: Int = 48000

    private var audioQueue: AudioQueueRef?
    private var audioTrackPlaybackSpeed: Float = 1
    private var stopTimestamp: Int64?
    
    private var lastPlayheadSampleTime: Int64 = 0
    private var stopPlaybackHeadPosition: Int64 = 0
    private var endPlaybackHeadPosition: Int64 = 0
    private var lastRawPlaybackHeadPositionSampleTime: Int64 = 0

    init(queue: Queue, clock: CMClock) {
        self.queue = queue
        self.clock = clock
    }

    func setAudioQueue(_ audioQueue: AudioQueueRef) {
        
    }

    func start() {
        if stopTimestamp != nil {
            stopTimestamp = clock.microseconds
        }
    }

    func hasPendingData(writtenFrames: Int) -> Bool {
        let currentPosition = currentPosition(sourseEnded: false)
        return writtenFrames > durationToSampleCount(duration: currentPosition, sampleRate: outputSampleRate)
    }

    func currentPosition(sourseEnded: Bool) -> Int64 {
        
    }

    private func maybeSampleSyncParams() {
        let systemTime = clock.microseconds
        
        if (systemTime - lastPlayheadSampleTime) >= .minPlayheadOffsetSampleInterval {
            let playbackPosition = playbackHeadPosition
        }
    }
}

private extension AudioPositionTracker {
    var playbackHeadPosition: Int64 {
        durationToSampleCount(duration: getPlaybackHeadPosition(), sampleRate: outputSampleRate)
    }

    func getPlaybackHeadPosition() -> Int64 {
        let currentTime = clock.microseconds
        if let stopTimestamp {
            if false {
                return stopPlaybackHeadPosition
            }
            let elapsedTimeSinceStop = currentTime - stopTimestamp
            let mediaTimeSinceStop = mediaDurationFor(playoutDuration: elapsedTimeSinceStop, speed: audioTrackPlaybackSpeed)
            let framesSinceStop = durationToSampleCount(duration: mediaTimeSinceStop, sampleRate: outputSampleRate)
            return min(endPlaybackHeadPosition, stopPlaybackHeadPosition + framesSinceStop)
        }

        if currentTime - lastRawPlaybackHeadPositionSampleTime >= .rawPlaybackHeadPositionUpdateInterval {
            updateRawPlaybackHeadPosition(currentTime: currentTime)
            lastRawPlaybackHeadPositionSampleTime = currentTime
        }
        
        return 0
    }
    
    private func updateRawPlaybackHeadPosition(currentTime: Int64) {
        guard let audioQueue else { return }
        
        var output: Int32 = 0
        var outputSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioQueueGetProperty(audioQueue, kAudioQueueProperty_IsRunning, &output, &outputSize)

        guard status != noErr, output == 1 else { return }
    }

    func mediaDurationFor(playoutDuration: Int64, speed: Float) -> Int64 {
        guard speed != 1 else { return playoutDuration }

        let result = (Double(playoutDuration) * Double(speed)).rounded(.up)
        return Int64(result)
    }
}

private extension AudioPositionTracker {
    func durationToSampleCount(duration: Int64, sampleRate: Int) -> Int64 {
        return scaleLargeValue(value: duration, multiplier: Int64(sampleRate), divisor: 1_000_000, roundingMode: .up)
    }

    func scaleLargeValue(value: Int64, multiplier: Int64, divisor: Int64, roundingMode: FloatingPointRoundingRule) -> Int64 {
        if value == 0 || multiplier == 0 {
            return 0
        }

        if divisor >= multiplier, divisor % multiplier == 0 {
            let divisionFactor = divisor / multiplier
            return divide(value, by: divisionFactor, roundingMode: roundingMode)
        } else if divisor < multiplier, multiplier % divisor == 0 {
            let multiplicationFactor = multiplier / divisor
            return saturatedMultiply(value, by: multiplicationFactor)
        } else if divisor >= value, divisor % value == 0 {
            let divisionFactor = divisor / value
            return divide(multiplier, by: divisionFactor, roundingMode: roundingMode)
        } else if divisor < value, value % divisor == 0 {
            let multiplicationFactor = value / divisor
            return saturatedMultiply(multiplier, by: multiplicationFactor)
        } else {
            return scaleLargeValueFallback(value: value, multiplier: multiplier, divisor: divisor, roundingMode: roundingMode)
        }
    }

    func divide(_ value: Int64, by divisor: Int64, roundingMode: FloatingPointRoundingRule) -> Int64 {
        let result = Double(value) / Double(divisor)
        return Int64(result.rounded(roundingMode))
    }

    func saturatedMultiply(_ value: Int64, by multiplier: Int64) -> Int64 {
        let multipledResult = value.multipliedReportingOverflow(by: multiplier)
        return multipledResult.overflow ? (value > 0 ? Int64.max : Int64.min) : multipledResult.partialValue
    }

    func scaleLargeValueFallback(value: Int64, multiplier: Int64, divisor: Int64, roundingMode: FloatingPointRoundingRule) -> Int64 {
        let scaledValue = Double(value) * Double(multiplier) / Double(divisor)
        return Int64(scaledValue.rounded(roundingMode))
    }
}

private extension Int64 {
    static let minPlayheadOffsetSampleInterval: Int64 = 30_000
    static let rawPlaybackHeadPositionUpdateInterval: Int64 = 5000
}
