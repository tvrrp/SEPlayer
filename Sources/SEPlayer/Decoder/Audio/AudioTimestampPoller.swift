//
//  AudioTimestampPoller.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.03.2025.
//

import AudioToolbox

final class AudioTimestampPoller {
    var hasTimestamp: Bool { state == .timestamp || state == .timestampAdvancing }
    var hasAdvancingTimestamp: Bool { state == .timestampAdvancing }
    var timestampSystemTime: Int64? { audioTimestamp?.getTimestampSystemTime() }
    var timestampPosition: Int64? { audioTimestamp?.getTimestampPosition() }

    private var audioTimestamp: AudioTimestampWrapper?

    private var state: State = .initializing
    private var lastTimestampSampleTime: Int64 = 0
    private var initialTimestampPosition: Int64 = 0
    private var initializeSystemTime: Int64 = 0
    private var sampleInterval: Int64 = 0

    func initialize(with audioQueue: AudioQueueRef) {
        audioTimestamp = AudioTimestampWrapper(audioQueue: audioQueue)
        reset()
    }

    func maybePoolTimestamp(systemTime: Int64) -> Bool {
        guard let audioTimestamp else { return false }

        if (systemTime - lastTimestampSampleTime) < sampleInterval {
            return false
        }

        lastTimestampSampleTime = systemTime
        var updatedTimestamp = audioTimestamp.maybeUpdateTimestamp()

        switch state {
        case .initializing:
            if updatedTimestamp {
                if audioTimestamp.getTimestampSystemTime() >= initializeSystemTime {
                    initialTimestampPosition = audioTimestamp.getTimestampPosition()
                    updateState(new: .timestamp)
                } else {
                    updatedTimestamp = false
                }
            } else if (systemTime - initializeSystemTime) > .initializingDuration {
                updateState(new: .noTimestamp)
            }
        case .timestamp:
            if updatedTimestamp {
                let timestampPosition = audioTimestamp.getTimestampPosition()
                if timestampPosition > initialTimestampPosition {
                    updateState(new: .timestampAdvancing)
                }
            } else {
                reset()
            }
        case .timestampAdvancing:
            if !updatedTimestamp {
                reset()
            }
        case .noTimestamp:
            if updatedTimestamp {
                reset()
            }
        default:
            break
        }

        return updatedTimestamp
    }

    func rejectTimestamp() {
        updateState(new: .error)
    }

    func acceptTimestamp() {
        if state == .error {
            reset()
        }
    }

    func reset() {
        updateState(new: .initializing)
    }

    func expectTimestampFramePositionReset() {
        audioTimestamp?.expectTimestampPositionReset = true
    }

    private func updateState(new state: State) {
        self.state = state
        switch state {
        case .initializing:
            lastTimestampSampleTime = 0
            initialTimestampPosition = 0
            initializeSystemTime = Int64(mach_absolute_time() / 1000)
            sampleInterval = .fastPoolInterval
        case .timestamp:
            sampleInterval = .fastPoolInterval
        case .timestampAdvancing, .noTimestamp:
            sampleInterval = .slowPoolInterval
        case .error:
            sampleInterval = .errorPoolInterval
        }
    }
}

extension AudioTimestampPoller {
    enum State {
        case initializing
        case timestamp
        case timestampAdvancing
        case noTimestamp
        case error
    }
}

extension AudioTimestampPoller {
    private final class AudioTimestampWrapper {
        var expectTimestampPositionReset: Bool = false

        private let audioQueue: AudioQueueRef
        private var audioTimeStamp: AudioTimeStamp
        private var currentSampleRate: Float64 = 0

        private var rawTimestampPositionWrapCount: Int = 0
        private var lastTimestampRawPosition: Float64 = 0
        private var lastTimestampPosition: Float64 = 0

        private var accumulatedRawTimestampPosition: Float64 = 0

        init(audioQueue: AudioQueueRef) {
            self.audioQueue = audioQueue
            audioTimeStamp = AudioTimeStamp()
        }

        func maybeUpdateTimestamp() -> Bool {
            let updated = updateTimeStamp()

            if updated {
                let rawPosition = audioTimeStamp.mSampleTime
                if lastTimestampRawPosition > rawPosition {
                    if expectTimestampPositionReset {
                        accumulatedRawTimestampPosition += lastTimestampPosition
                        expectTimestampPositionReset = false
                    } else {
                        rawTimestampPositionWrapCount += 1
                    }
                }

                lastTimestampRawPosition = rawPosition
                lastTimestampPosition = rawPosition + accumulatedRawTimestampPosition
            }

            return updated
        }

        func getTimestampSystemTime() -> Int64 {
            Int64(audioTimeStamp.mHostTime / 1000)
        }

        func getTimestampPosition() -> Int64 {
            Int64(lastTimestampPosition)
        }

        private func updateTimeStamp() -> Bool {
            let timeStatus = AudioQueueGetCurrentTime(audioQueue, nil, &audioTimeStamp, nil)

            var size = Int32(MemoryLayout.size(ofValue: currentSampleRate))
            let rateStatus = AudioQueueGetProperty(audioQueue, kAudioQueueDeviceProperty_SampleRate, &currentSampleRate, &size)

            return timeStatus == noErr && rateStatus == noErr
        }
    }
}

private extension Int64 {
    static let fastPoolInterval: Int64 = 10_000
    static let slowPoolInterval: Int64 = 10_000_000
    static let errorPoolInterval: Int64 = 500_000
    static let initializingDuration: Int64 = 500_000
}
