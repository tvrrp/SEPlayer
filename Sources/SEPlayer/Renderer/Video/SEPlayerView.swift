//
//  SEPlayerView.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import CoreVideo
import UIKit

public final class SEPlayerView: UIView {

    public override class var layerClass: AnyClass {
        CALayer.self
    }

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

    public var gravity: CALayerContentsGravity {
        get { layer.contentsGravity }
        set { layer.contentsGravity = newValue }
    }

    private weak var _player: Player?
    private var currentImageBuffer: CVImageBuffer?

    public init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError()
    }
}

extension SEPlayerView: PlayerBufferable {
    public func prepare(for action: PlayerBufferableAction) {
        if action == .reset {
            layer.contents = nil
        }
    }

    public func enqueue(_ buffer: CVPixelBuffer) {
        currentImageBuffer = buffer
        #if targetEnvironment(simulator)
        layer.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        #else
        layer.contents = buffer
        #endif
    }

    public func end() {
        currentImageBuffer = nil
    }
}

private extension SEPlayerView {
    @MainActor
    func _set(player: Player?) {
        _player?.remove(self)
        layer.contents = nil

        player?.register(self)
        _player = player
    }
}
