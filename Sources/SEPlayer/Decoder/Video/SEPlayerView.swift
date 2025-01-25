//
//  SEPlayerView.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import CoreMedia
import UIKit

internal protocol SEPlayerBufferView {
    var outputWindowScene: UIWindowScene? { get }
    func setBufferQueue(_ bufferQueue: TypedCMBufferQueue<VTRenderer.SampleReleaseWrapper>)
    func enqueueSampleImmideatly(_ sample: CMSampleBuffer)
    func displayLinkTick(_ displayLink: CADisplayLink)
}

public final class SEPlayerView: UIView {
    public override class var layerClass: AnyClass {
        CALayer.self
    }

    var outputWindowScene: UIWindowScene? {
        assert(Queues.mainQueue.isCurrent())
        return self.window?.windowScene
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
    private var sampleQueue: TypedCMBufferQueue<VTRenderer.SampleReleaseWrapper>?

    public init() {
        super.init(frame: .zero)
    }

    public required init?(coder: NSCoder) {
        fatalError()
    }
}

extension SEPlayerView: SEPlayerBufferView {
    func setBufferQueue(_ bufferQueue: TypedCMBufferQueue<VTRenderer.SampleReleaseWrapper>) {
        self.sampleQueue = bufferQueue
    }

    func enqueueSampleImmideatly(_ sample: CMSampleBuffer) {
        displaySample(sample)
    }

    func displayLinkTick(_ displayLink: CADisplayLink) {
        assert(Queues.mainQueue.isCurrent())
        guard let sampleQueue else { return }
        let frameDeadlineRange = displayLink.timestampNs..<displayLink.targetTimestampNs

        if let sampleWrapper = sampleQueue.dequeue() {
            if frameDeadlineRange.contains(sampleWrapper.releaseTime) {
                displaySample(sampleWrapper.sample)
            } else if sampleWrapper.releaseTime > frameDeadlineRange.upperBound {
                try! sampleQueue.enqueue(sampleWrapper)
            }
        }
    }

    private func displaySample(_ sample: CMSampleBuffer) {
        guard let imageBuffer = sample.imageBuffer else { return }
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

private extension CADisplayLink {
    var timestampNs: Int64 {
        Int64(timestamp * 1_000_000_000)
    }

    var targetTimestampNs: Int64 {
        Int64(targetTimestamp * 1_000_000_000)
    }
}
