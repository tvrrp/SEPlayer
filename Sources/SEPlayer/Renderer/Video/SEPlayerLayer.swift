//
//  SEPlayerLayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AVFoundation
import QuartzCore
import SEPlayerCommon
#if canImport(UIKit)
import UIKit
#endif

/// Shows the video of ``player``. The display layers come from the player's video renderer and
/// fill the layer's bounds.
///
/// Use it as a view's layer (`layerClass`) to have the video follow the view's animated size
/// changes, such as rotation: the picture then moves and scales with the layer's own animation.
///
/// Like any layer, use it on the main thread.
@MainActor
public final class SEPlayerLayer: CALayer, VideoOutput {
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

    /// How the video fills the bounds.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayers.forEach { $0.videoGravity = videoGravity }
            CATransaction.commit()
            updateVideoRect()
        }
    }

    /// The size of the video on screen, with the pixel aspect ratio and the clean aperture applied.
    /// `.zero` until the first sample of the video is known. Key-value observable.
    @objc public private(set) dynamic var presentationSize: CGSize = .zero

    /// Where the picture is in the layer's bounds, given ``videoGravity``; larger than the bounds
    /// when the video fills them. `.zero` until the video's size is known. Key-value observable.
    @objc public private(set) dynamic var videoRect: CGRect = .zero

    private var displayLayers: [AVSampleBufferDisplayLayer] = []
    private weak var _player: SEPlayer?

    public override init() {
        super.init()
    }

    /// Core Animation's copies, such as the presentation layer.
    public override init(layer: Any) {
        super.init(layer: layer)
        guard let layer = layer as? SEPlayerLayer else { return }
        videoGravity = layer.videoGravity
        presentationSize = layer.presentationSize
        videoRect = layer.videoRect
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: - VideoOutput

    @MainActor
    public func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.videoGravity = videoGravity
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        displayLayer.frame = bounds
        addSublayer(displayLayer)
        CATransaction.commit()

        displayLayers.append(displayLayer)
    }

    @MainActor
    public func detach(_ displayLayer: AVSampleBufferDisplayLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.removeFromSuperlayer()
        CATransaction.commit()

        displayLayers.removeAll { $0 === displayLayer }
    }

    @MainActor
    public func setPresentationSize(_ size: CGSize) {
        guard size != presentationSize else { return }
        presentationSize = size
        updateVideoRect()
    }

    // MARK: - Layout

    public override func layoutSublayers() {
        super.layoutSublayers()
        layoutDisplayLayers()
        updateVideoRect()
    }

    private func layoutDisplayLayers() {
        let animation = resizeAnimation()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for displayLayer in displayLayers {
            displayLayer.frame = bounds
            if let animation {
                displayLayer.add(animation, forKey: "SEPlayerLayer.resize")
            }
        }
        CATransaction.commit()
    }

    /// The layer's running size animation, remade as a transform for the display layers.
    ///
    /// UIKit animates a view's layer when the view changes size, as in a rotation or a move to
    /// full screen. A display layer can't follow by animating its own size: the layer inside it
    /// that draws the picture is laid out once, at the final size, so the picture would jump
    /// there and grow out of the top left corner. Instead the display layers take their final
    /// frame at once, and a transform that starts with the picture where it was — scaled and
    /// moved from the old video rect to the new one — runs back to identity with the layer's
    /// own timing.
    private func resizeAnimation() -> CAAnimation? {
        for key in animationKeys() ?? [] {
            guard
                let animation = animation(forKey: key) as? CABasicAnimation,
                let keyPath = animation.keyPath,
                keyPath == "bounds.size" || keyPath == "bounds",
                let from = size(from: animation.fromValue)
            else {
                continue
            }

            // Additive animations run from the difference to zero, onto the model value.
            let fromSize = animation.isAdditive
                ? CGSize(width: bounds.width + from.width, height: bounds.height + from.height)
                : from
            guard fromSize.width > 0, fromSize.height > 0, !bounds.isEmpty else { return nil }

            let oldRect = pictureRect(in: CGRect(origin: bounds.origin, size: fromSize))
            let newRect = pictureRect(in: bounds)
            guard newRect.width > 0, newRect.height > 0 else { return nil }

            // A display layer's anchor is the middle of the bounds; the transform works around it.
            let anchor = CGPoint(x: bounds.midX, y: bounds.midY)
            var transform = CATransform3DMakeTranslation(oldRect.midX - anchor.x, oldRect.midY - anchor.y, 0)
            transform = CATransform3DScale(transform, oldRect.width / newRect.width, oldRect.height / newRect.height, 1)
            transform = CATransform3DTranslate(transform, anchor.x - newRect.midX, anchor.y - newRect.midY, 0)

            let resize = animation.copy() as! CABasicAnimation
            resize.keyPath = "transform"
            resize.isAdditive = false
            resize.fromValue = NSValue(caTransform3D: transform)
            resize.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            return resize
        }
        return nil
    }

    /// Where the picture is in `bounds`: the video rect once the video's size is known, the whole
    /// bounds before.
    private func pictureRect(in bounds: CGRect) -> CGRect {
        let rect = Self.videoRect(for: presentationSize, in: bounds, gravity: videoGravity)
        return rect.isEmpty ? bounds : rect
    }

    private func size(from value: Any?) -> CGSize? {
        guard let value = value as? NSValue else { return nil }
        let type = String(cString: value.objCType)
        if type == String(cString: NSValue(size: .zero).objCType) {
            return value.size
        } else if type == String(cString: NSValue(rect: .zero).objCType) {
            return value.rect.size
        }
        return nil
    }

    private func updateVideoRect() {
        let rect = Self.videoRect(for: presentationSize, in: bounds, gravity: videoGravity)
        if rect != videoRect {
            videoRect = rect
        }
    }

    private static func videoRect(for size: CGSize, in bounds: CGRect, gravity: AVLayerVideoGravity) -> CGRect {
        guard size.width > 0, size.height > 0, !bounds.isEmpty else { return .zero }

        switch gravity {
        case .resizeAspect:
            return AVMakeRect(aspectRatio: size, insideRect: bounds)
        case .resizeAspectFill:
            let scale = max(bounds.width / size.width, bounds.height / size.height)
            let fill = CGSize(width: size.width * scale, height: size.height * scale)
            return CGRect(
                x: bounds.midX - fill.width / 2,
                y: bounds.midY - fill.height / 2,
                width: fill.width,
                height: fill.height
            )
        default:
            return bounds
        }
    }
}

private extension SEPlayerLayer {
    @MainActor
    func _set(player: SEPlayer?) {
        guard player !== _player else { return }
        _player?.removeVideoOutput(self)
        setPresentationSize(.zero)
        player?.setVideoOutput(self)
        _player = player
    }
}

private extension NSValue {
    #if canImport(UIKit)
    convenience init(size: CGSize) { self.init(cgSize: size) }
    convenience init(rect: CGRect) { self.init(cgRect: rect) }
    var size: CGSize { cgSizeValue }
    var rect: CGRect { cgRectValue }
    #else
    var size: CGSize { sizeValue }
    var rect: CGRect { rectValue }
    #endif
}
