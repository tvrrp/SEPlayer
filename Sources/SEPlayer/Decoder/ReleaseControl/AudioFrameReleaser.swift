//
//  AudioFrameReleaser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.01.2025.
//

import AVFoundation

final class AudioFrameReleaser: SampleReleaser {
    var isReady: Bool { queue.sync { didProduceEnothSamples() } }

    private let queue: Queue
    private let decompressedSamplesQueue: TypedCMBufferQueue<CMSampleBuffer>
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let timebase: CMTimebase
    private let timer: DispatchSourceTimer

    private var needsFirstDequeue: Bool = true
    private var currentSample = 0
    private var timerTimestamps: [CMTime] = []
    private var lastDecodedTime: CMTime = .zero

    init(
        queue: Queue,
        decompressedSamplesQueue: TypedCMBufferQueue<CMSampleBuffer>,
        audioRenderer: AVSampleBufferAudioRenderer,
        timebase: CMTimebase
    ) throws {
        self.queue = queue
        self.decompressedSamplesQueue = decompressedSamplesQueue
        self.audioRenderer = audioRenderer
        self.timebase = timebase
        self.timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue.queue)

        try createTimer()
    }

    func dequeueFirstSampleIfNeeded() {
        queue.async { [self] in
            guard needsFirstDequeue, automaticDequeue() else { return }
            if audioRenderer.hasSufficientMediaDataForReliablePlaybackStart {
                needsFirstDequeue = false
                try? timebase.setTimerToFireImmediately(timer)
            }
//            if currentSample < 10 {
//                dequeueFirstSampleIfNeeded()
//            } else {
//                needsFirstDequeue = false
//                try? timebase.setTimerToFireImmediately(timer)
//            }
        }
    }

    @discardableResult
    private func automaticDequeue() -> Bool {
        assert(queue.isCurrent())
        guard !audioRenderer.hasSufficientMediaDataForReliablePlaybackStart else {
            return false
        }
        if let sampleBuffer = decompressedSamplesQueue.dequeue() {
            lastDecodedTime = sampleBuffer.presentationTimeStamp
            timerTimestamps.append(sampleBuffer.presentationTimeStamp)
            audioRenderer.enqueue(sampleBuffer)
            print("😎 audioRenderer.isReady = \(audioRenderer.hasSufficientMediaDataForReliablePlaybackStart), didEnqueue = \(lastDecodedTime.seconds), currentTime = \(timebase.time.seconds)")
            currentSample += 1
            return audioRenderer.hasSufficientMediaDataForReliablePlaybackStart ? true : automaticDequeue()
        } else {
            return false
        }
    }

    private func didProduceEnothSamples() -> Bool {
        return !needsFirstDequeue
    }
}

private extension AudioFrameReleaser {
    func createTimer() throws {
        timer.setEventHandler { [weak self] in
            guard let self else { return }
//            print("🔥 timer did fire = \(timebase.time.seconds), items = \(decompressedSamplesQueue.bufferCount), last = \(lastDecodedTime.seconds)")
            automaticDequeue()
            if !timerTimestamps.isEmpty {
                let nextTimerTick = timerTimestamps.removeFirst()
//                print("✅ nextTime = \(nextTimerTick.seconds)")
                try? timebase.setTimerNextFireTime(timer, fireTime: nextTimerTick)
            }
        }
        timer.activate()
        try timebase.addTimer(timer)
    }
}
