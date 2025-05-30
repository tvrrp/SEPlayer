//
//  PlayerBufferable.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

import CoreVideo

final class PlayerBufferableContainer {
    private let displayLink: DisplayLinkProvider

    private var action: PlayerBufferableAction = .reset
    private(set) var bufferables: [PlayerBufferable] = []

    private var sampleQueue: TypedCMBufferQueue<ImageBufferWrapper>?
    private var lastPixelBuffer: CVPixelBuffer?

    public init(displayLink: DisplayLinkProvider) {
        self.displayLink = displayLink
    }

    func prepare(sampleQueue: TypedCMBufferQueue<ImageBufferWrapper>) {
        Queues.mainQueue.async { [self] in
            self.sampleQueue = sampleQueue
            lastPixelBuffer = nil

            bufferables.forEach { $0.prepare(for: action) }
        }
    }

    func end() {
        Queues.mainQueue.async { [self] in
            self.sampleQueue = nil
            bufferables.forEach { $0.end() }
        }

        displayLink.removeOutput(self)
    }

    func start() {
        displayLink.addOutput(self)
    }

    func stop() {
        displayLink.removeOutput(self)
    }

    func flush() {
        Queues.mainQueue.async { self.lastPixelBuffer = nil }
    }

    func register(_ bufferable: PlayerBufferable) {
        Queues.mainQueue.async { [self] in
            bufferables.append(bufferable)

            if let lastPixelBuffer {
                bufferable.enqueue(lastPixelBuffer)
            }
        }
    }

    func remove(_ bufferable: PlayerBufferable) {
        Queues.mainQueue.async { [self] in
            bufferables.removeAll(where: { $0.equal(to: bufferable) })
        }
    }

    func renderImmediately(_ pixelBuffer: CVPixelBuffer) {
        Queues.mainQueue.async { [self] in
            lastPixelBuffer = pixelBuffer
            bufferables.forEach { $0.enqueue(pixelBuffer) }
        }
    }
}

extension PlayerBufferableContainer: DisplayLinkListener {
    func displayLinkTick(_ info: DisplayLinkInfo) {
        let deadline = info.currentTimestampNs...info.targetTimestampNs

        if let sampleWrapper = sampleQueue?.dequeue() {
            if sampleWrapper.presentationTime > info.targetTimestampNs {
                print("ℹ️ pixel buffer is early")
                try? sampleQueue?.enqueue(sampleWrapper)
            } else if deadline.contains(sampleWrapper.presentationTime) {
                guard let pixelBuffer = sampleWrapper.imageBuffer else { return }
                lastPixelBuffer = pixelBuffer
                bufferables.forEach { $0.enqueue(pixelBuffer) }
                print("💕 enqueuing pixel buffer")
            } else {
                print("💔 missed sample")
                displayLinkTick(info)
            }
        }
    }
}
