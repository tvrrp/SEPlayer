//
//  SEPlayerView.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AVFoundation
import UIKit

protocol SEPlayerBufferView: DisplayLinkListener {
    func setBufferQueue(_ bufferQueue: TypedCMBufferQueue<ImageBufferWrapper>)
    func enqueueSampleImmediately(_ sample: ImageBufferWrapper)
}

public final class SEPlayerView: UIView {
    public override class var layerClass: AnyClass {
        CALayer.self
    }

    public weak var player: SEPlayer? {
        get {
            assert(Queues.mainQueue.isCurrent())
            return _player
        }
        set { set(player: newValue) }
    }

    public var gravity: CALayerContentsGravity {
        get { layer.contentsGravity }
        set { layer.contentsGravity = newValue }
    }

    private weak var _player: SEPlayer?
    private var sampleQueue: TypedCMBufferQueue<ImageBufferWrapper>?
    private var currentImageBuffer: CVImageBuffer?

    public init() {
        super.init(frame: .zero)
    }

    public required init?(coder: NSCoder) {
        fatalError()
    }
}

extension SEPlayerView: SEPlayerBufferView {
    func setBufferQueue(_ bufferQueue: TypedCMBufferQueue<ImageBufferWrapper>) {
        assert(Queues.mainQueue.isCurrent())
        self.sampleQueue = bufferQueue
    }

    func enqueueSampleImmediately(_ sample: ImageBufferWrapper) {
        assert(Queues.mainQueue.isCurrent())
        displaySample(sample)
    }

    func displayLinkTick(_ info: DisplayLinkInfo) {
        assert(Queues.mainQueue.isCurrent())
        let deadline = info.currentTimestampNs...info.targetTimestampNs

        if let sampleWrapper = sampleQueue?.dequeue() {
            if sampleWrapper.presentationTime > info.targetTimestampNs {
                try? sampleQueue?.enqueue(sampleWrapper)
            } else if deadline.contains(sampleWrapper.presentationTime) {
                displaySample(sampleWrapper)
            } else {
                displayLinkTick(info)
            }
        }
    }

    private func displaySample(_ sample: ImageBufferWrapper) {
        guard let imageBuffer = sample.imageBuffer else { return }
        currentImageBuffer = imageBuffer
        #if targetEnvironment(simulator)
        layer.contents = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue()
        #else
        layer.contents = imageBuffer
        #endif
    }
}

extension SEPlayerView: PlayerBufferable {
    func prepare(for action: PlayerBufferableAction) {
        if action == .reset {
            layer.contents = nil
        }
    }

    func enqueue(_ buffer: CVPixelBuffer) {
        currentImageBuffer = buffer
        #if targetEnvironment(simulator)
        layer.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        #else
        layer.contents = buffer
        #endif
    }

    func end() {
        currentImageBuffer = nil
    }
}

private extension SEPlayerView  {
    func set(player: SEPlayer?) {
        assert(Queues.mainQueue.isCurrent())
//        _player?.removeBufferOutput(self)
        _player?.remove(self)
        layer.contents = nil

        sampleQueue = nil
//        player?.setBufferOutput(self)
        player?.register(self)
        _player = player
    }
}
