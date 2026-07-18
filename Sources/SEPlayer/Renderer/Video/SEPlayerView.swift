//
//  SEPlayerView.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

#if canImport(UIKit)
import UIKit
public typealias SEPlatformView = UIView
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
public typealias SEPlatformView = NSView
#endif

#if canImport(UIKit) || canImport(AppKit)
import AVFoundation
import SEPlayerCommon

public protocol SEPlayerViewDelegate: AnyObject {
    func willRenderNewBuffer(_ view: SEPlayerView, of size: CGSize)
}

public final class SEPlayerView: SEPlatformView {
#if canImport(UIKit)
    public override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }
#endif

    @MainActor public weak var delegate: SEPlayerViewDelegate?

    @MainActor public weak var player: SEPlayer? {
        get {
            assert(Queues.mainQueue.isCurrent())
            return _player
        }
        set {
            assert(Queues.mainQueue.isCurrent())
            _set(player: newValue)
        }
    }

    @MainActor public var gravity: AVLayerVideoGravity {
        get { displayLayer.videoGravity }
        set { displayLayer.videoGravity = newValue }
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private weak var _player: SEPlayer?

    public init() {
        super.init(frame: .zero)
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        wantsLayer = true
#endif
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError()
    }

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    public override func makeBackingLayer() -> CALayer {
        AVSampleBufferDisplayLayer()
    }
#endif
}

private extension SEPlayerView {
    @MainActor
    func _set(player: SEPlayer?) {
        _player?.removeVideoOutput(displayLayer.createRenderer())

        player?.setVideoOutput(displayLayer.createRenderer())
        _player = player
    }
}

#endif
