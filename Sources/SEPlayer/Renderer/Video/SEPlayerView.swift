//
//  SEPlayerView.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AVFoundation
import UIKit

public protocol SEPlayerViewDelegate: AnyObject {
    func willRenderNewBuffer(_ view: SEPlayerView, of size: CGSize)
}

public final class SEPlayerView: UIView {
    public override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    @MainActor public weak var delegate: SEPlayerViewDelegate?

    @MainActor public weak var player: Player? {
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

    private weak var _player: Player?

    private var oldIsReadyForMoreMediaData: Bool = true
    private let lock = UnfairLock()

    public init() {
        super.init(frame: .zero)
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError()
    }
}

private extension SEPlayerView {
    @MainActor
    func _set(player: Player?) {
        _player?.removeVideoOutput(displayLayer.createRenderer())

        player?.setVideoOutput(displayLayer.createRenderer())
        _player = player
    }
}
