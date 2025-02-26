//
//  SEPlayerView.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AVFoundation
import UIKit

protocol SEPlayerBufferView: DisplayLinkListener {
    func setBufferQueue(_ bufferQueue: TypedCMBufferQueue<CMSampleBuffer>)
    func enqueueSampleImmediately(_ sample: CMSampleBuffer)
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
    private var sampleQueue: TypedCMBufferQueue<CMSampleBuffer>?
    private var currentSample: CMSampleBuffer?

    public init() {
        super.init(frame: .zero)
    }

    public required init?(coder: NSCoder) {
        fatalError()
    }
}

extension SEPlayerView: SEPlayerBufferView {
    func setBufferQueue(_ bufferQueue: TypedCMBufferQueue<CMSampleBuffer>) {
        assert(Queues.mainQueue.isCurrent())
        self.sampleQueue = bufferQueue
    }

    func enqueueSampleImmediately(_ sample: CMSampleBuffer) {
        assert(Queues.mainQueue.isCurrent())
        displaySample(sample)
    }

    func displayLinkTick(_ info: DisplayLinkInfo) {
        assert(Queues.mainQueue.isCurrent())
        let deadline = info.currentTimestampNs...info.targetTimestampNs

        if let sampleBuffer = sampleQueue?.dequeue() {
            if sampleBuffer.presentationTimeStamp.nanoseconds > info.targetTimestampNs {
                try! sampleQueue?.enqueue(sampleBuffer)
            } else if deadline.contains(sampleBuffer.presentationTimeStamp.nanoseconds) {
                displaySample(sampleBuffer)
            } else {
                displayLinkTick(info)
            }
        }
    }

    private func displaySample(_ sample: CMSampleBuffer) {
        guard let imageBuffer = sample.imageBuffer else { return }
        currentSample = sample
        #if targetEnvironment(simulator)
        layer.contents = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue()
        #else
        layer.contents = imageBuffer
        #endif
    }
}

private extension SEPlayerView  {
    func set(player: SEPlayer?) {
        assert(Queues.mainQueue.isCurrent())
        _player?.removeBufferOutput(self)
        layer.contents = nil

        sampleQueue = nil
        player?.setBufferOutput(self)
        _player = player
    }
}
