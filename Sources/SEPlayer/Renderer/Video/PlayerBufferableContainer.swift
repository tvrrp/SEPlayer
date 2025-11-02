//
//  PlayerBufferable.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

import AVFoundation

public final class PlayerBufferableContainer {
    private var action: PlayerBufferableAction = .reset
    private(set) var bufferables: [PlayerBufferable] = []

    private var sampleQueue: TypedCMBufferQueue<ImageBufferWrapper>?
    private var timebase: CMTimebase?
    private var lastSampleBuffer: CMSampleBuffer?
    private var lastFormat: Format?

    private var didRenderFirstFrame = false
    private var isStarted = false

    public init() {}

    func prepare(action: PlayerBufferableAction) {
        lastSampleBuffer = nil
        lastFormat = nil

        bufferables.forEach { $0.prepare(for: action) }
    }

    func requestMediaDataWhenReady(on queue: Queue, block: @escaping () -> Void) {
        bufferables.forEach { bufferable in
            bufferable.requestMediaDataWhenReady(on: queue, block: block)
        }
    }

    func stopRequestingMediaData() {
        bufferables.forEach { $0.stopRequestingMediaData() }
    }

    func setControlTimebase(_ timebase: CMTimebase) {
        self.timebase = timebase

        bufferables.forEach { $0.setControlTimebase(timebase) }
    }

    func end() {
        sampleQueue = nil
        timebase = nil

        bufferables.forEach { $0.end() }
    }

    func start() {
        isStarted = true
    }

    func stop() {
        isStarted = false
    }

    func flush() {
        didRenderFirstFrame = false
        lastSampleBuffer = nil
        lastFormat = nil

        bufferables.forEach { $0.end() }
    }

    func register(_ bufferable: PlayerBufferable) {
        bufferables.append(bufferable)

        if let timebase {
            bufferable.setControlTimebase(timebase)
        }

        if let lastSampleBuffer {
            bufferable.enqueue(lastSampleBuffer, format: lastFormat)
        }
    }

    func remove(_ bufferable: PlayerBufferable) {
        bufferables.removeAll(where: { $0.equal(to: bufferable) })
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, format: Format?) -> Bool {
        guard isStarted || !didRenderFirstFrame else { return false }
        didRenderFirstFrame = true
        guard bufferables.allSatisfy({ $0.isReadyForMoreMediaData }) else {
            return false
        }

        lastSampleBuffer = sampleBuffer
        bufferables.forEach { $0.enqueue(sampleBuffer, format: format) }
        return true
    }
}
