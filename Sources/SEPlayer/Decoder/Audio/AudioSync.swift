//
//  AudioSync.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AudioToolbox
import AVFoundation

final class AudioSync {
    private let queue: Queue
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let outputQueue: TypedCMBufferQueue<CMSampleBuffer>
    private let outputSampleRate: Double

    private var writtenFrames: Int = 0

    init(
        queue: Queue,
        audioRenderer: AVSampleBufferAudioRenderer,
        outputQueue: TypedCMBufferQueue<CMSampleBuffer>,
        outputSampleRate: Double
    ) {
        self.queue = queue
        self.audioRenderer = audioRenderer
        self.outputQueue = outputQueue
        self.outputSampleRate = outputSampleRate
    }

    func hasPendingData() -> Bool {
        let currentPosition = audioRenderer.timebase.time.microseconds - 1_000_000_000_000
        return writtenFrames > durationToSampleCount(duration: currentPosition, sampleRate: Int(outputSampleRate))
    }

    func start() {
        audioRenderer.requestMediaDataWhenReady(on: queue.queue) { [weak self] in
            guard let self else { return }
            while audioRenderer.isReadyForMoreMediaData,
                  let sampleBuffer = outputQueue.dequeue() {
                enqueueImmediately(sampleBuffer)
            }
        }
    }

    func enqueueImmediately(_ buffer: CMSampleBuffer) {
        audioRenderer.enqueue(buffer)
        writtenFrames += buffer.numSamples
    }
}

private extension AudioSync {
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

final class AudioSync2 {
    private var audioQueue: AudioQueueRef?
    private var outputFormat: AudioStreamBasicDescription
    private let queue: Queue
    
    init(queue: Queue, outputFormat: AudioStreamBasicDescription) {
        self.queue = queue
        self.outputFormat = outputFormat
    }

    func start() throws {
        guard let audioQueue else { return }
        var startTime = AudioTimeStamp()
        startTime.mHostTime = 10

        AudioQueueStart(audioQueue, &startTime)
    }
}

private extension AudioSync2 {
    private func createAudioQueue() throws {
        let status = AudioQueueNewOutputWithDispatchQueue(
            &audioQueue, &outputFormat, 0, queue.queue
        ) { [weak self] audioQueue, audioBuffer in
            self?.handleAudioQueueCallback(audioQueue: audioQueue, buffer: audioBuffer)
        }

        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func handleAudioQueueCallback(audioQueue: AudioQueueRef, buffer: AudioQueueBufferRef) {
//        buffer.pointee.
    }
}
