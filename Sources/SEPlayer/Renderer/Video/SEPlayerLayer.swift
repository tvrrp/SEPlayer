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

/// Shows the video of ``player``. The display layers come from the player's video renderer; each takes
/// the frame of the picture, which the layer crops when the video fills it.
///
/// The player's subtitles show on top, in ``subtitleLayer``, positioned in the picture of the video.
///
/// Use it as a view's layer (`layerClass`) to have the video follow the view's animated size
/// changes, such as rotation: the picture then moves and scales with the layer's own animation.
///
/// Like any layer, use it on the main thread.
@MainActor
public final class SEPlayerLayer: CALayer, VideoOutput, SEPlayerDelegate {
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
    ///
    /// The display layers don't apply it themselves: each is the size of the picture, larger than the bounds when
    /// the video fills them, and this layer crops it. A display layer that filled its bounds would crop the picture
    /// itself, and any animation of the picture would start already cropped.
    ///
    /// A display layer sizes its picture to the last frame enqueued, ahead of the frames still to show, so the display
    /// layers get a gravity that keeps the frame on screen exactly in the frame placed here; see
    /// ``displayLayerGravity``.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            updateVideoRect()
            layoutDisplayLayerFrames()
            updateSubtitleViewport()
            updateVideoOutputSize()
        }
    }

    /// Excludes the video from screenshots and screen recordings, as for protected content.
    public var preventsCapture = false {
        didSet {
            guard preventsCapture != oldValue else {
                return
            }

            displayLayers.forEach { setPreventsCapture(preventsCapture, on: $0) }
        }
    }

    /// Sets ``videoGravity``.
    ///
    /// - Parameter animated: Whether the picture scales to its new size. A display layer can't animate its
    ///   size: the picture would jump there. Instead it takes the new size at once, and a transform that
    ///   starts with the picture where it was runs back to identity.
    public func setVideoGravity(_ gravity: AVLayerVideoGravity, animated: Bool) {
        guard gravity != videoGravity else { return }
        let oldRect = displayLayerFrame(in: bounds)
        videoGravity = gravity
        let newRect = displayLayerFrame(in: bounds)
        guard animated, oldRect != newRect, newRect.width > 0, newRect.height > 0 else {
            return
        }

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: transform(from: oldRect, to: newRect, anchor: newRect.center))
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        displayLayers.filter { $0 is AVSampleBufferDisplayLayer }
            .forEach { $0.add(animation, forKey: "SEPlayerLayer.videoGravity") }

        // The subtitles are laid out again in the new picture; they fade there rather than jump.
        let fade = CATransition()
        fade.type = .fade
        fade.duration = animation.duration
        subtitleLayer.add(fade, forKey: "SEPlayerLayer.videoGravity")
    }

    /// The size of the video on screen, with the pixel aspect ratio and the clean aperture applied.
    /// `.zero` until the first sample of the video is known. Key-value observable.
    @objc public private(set) dynamic var presentationSize: CGSize = .zero

    /// Where the picture is in the layer's bounds, given ``videoGravity``; larger than the bounds
    /// when the video fills them. `.zero` until the video's size is known. Key-value observable.
    @objc public private(set) dynamic var videoRect: CGRect = .zero

    /// Shows the subtitles of ``player``. Use it to style them.
    public let subtitleLayer = SESubtitleLayer()

    /// The size last reported to ``player`` as the size this layer shows the picture at, in pixels.
    private var reportedVideoOutputSize: CGSize?

    #if canImport(UIKit)
    /// Room the subtitles keep clear of, measured from the edges of the picture: they are laid out in the picture
    /// inset by these, which may reach past it, within the bounds. A player view sets them to keep the subtitles
    /// above its controls.
    public private(set) var legibleContentInsets: UIEdgeInsets = .zero

    /// Sets ``legibleContentInsets``.
    ///
    /// - Parameter animated: Whether the subtitles fade to their new place, as controls do when they come and go.
    public func setLegibleContentInsets(_ insets: UIEdgeInsets, animated: Bool) {
        guard insets != legibleContentInsets else { return }
        legibleContentInsets = insets
        if animated {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.15
            transition.timingFunction = CAMediaTimingFunction(name: .linear)
            subtitleLayer.add(transition, forKey: "SEPlayerLayer.legibleContentInsets")
        }
        updateSubtitleViewport()
    }
    #endif

    /// The layers of the renderers: sample buffer display layers, placed here, and image queue layers, which fill the
    /// bounds and lay out each frame themselves.
    private var displayLayers: [CALayer] = []
    /// The size the video changes to, and the host time it does; see ``setPresentationSize(_:at:)``.
    private var upcomingSize: (size: CGSize, hostTime: CFTimeInterval)?
    private weak var _player: SEPlayer?

    public override init() {
        super.init()
        // A picture that fills the bounds is larger than them.
        masksToBounds = true
        addSublayer(subtitleLayer)
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
    public func attach(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let displayLayer = layer as? AVSampleBufferDisplayLayer {
            displayLayer.videoGravity = Self.displayLayerGravity
            // A frame shown before its size reaches here is cropped to the old shape rather than spilling over.
            displayLayer.masksToBounds = true
            displayLayer.preventsDisplaySleepDuringVideoPlayback = true
            displayLayer.frame = displayLayerFrame(in: bounds)
        } else {
            // It lays out each frame itself, in the shape of the frame.
            layer.contentsGravity = Self.contentsGravity(for: videoGravity)
            layer.frame = bounds
        }
        insertSublayer(layer, below: subtitleLayer)
        if let resize = resizeAnimations() {
            layer.add(layer is AVSampleBufferDisplayLayer ? resize.picture : resize.bounds, forKey: "SEPlayerLayer.resize")
        }
        holdUpcomingSize(in: [layer])
        CATransaction.commit()

        if preventsCapture {
            setPreventsCapture(true, on: layer)
        }

        displayLayers.append(layer)
    }

    @MainActor
    public func detach(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        CATransaction.commit()

        // The renderer may show the layer in another output next.
        if preventsCapture {
            setPreventsCapture(false, on: layer)
        }

        displayLayers.removeAll { $0 === layer }
    }

    /// A size given ahead of its time is applied by the render server, at that time, together with the frame: the
    /// display layers take the frame of the new picture at once, and a transform holds the frames still on screen
    /// in the old one until the time comes. ``presentationSize``, ``videoRect`` and the subtitles follow once the
    /// renderer tells the size is on screen: the time can still move, as when the clock stops just before it.
    @MainActor
    public func setPresentationSize(_ size: CGSize, at hostTime: CFTimeInterval?) {
        if let hostTime, hostTime > CACurrentMediaTime(), presentationSize != .zero, size != presentationSize {
            upcomingSize = (size, hostTime)
            layoutDisplayLayerFrames()
            return
        }

        let held = upcomingSize
        upcomingSize = nil
        // A hold for this size ends on its own, at the time of the frame; one for another size, dropped by a flush or
        // replaced, goes now.
        if let held, held.size != size {
            displayLayers.forEach { $0.removeAnimation(forKey: Self.holdAnimationKey) }
        }
        guard size != presentationSize else {
            if held != nil { layoutDisplayLayerFrames() }
            return
        }
        presentationSize = size
        updateVideoRect()
        layoutDisplayLayerFrames()
        updateSubtitleViewport()
        updateVideoOutputSize()
    }

    // MARK: - SEPlayerDelegate

    public func player(_ player: Player, didChangeCues cueGroup: CueGroup) {
        subtitleLayer.setCues(cueGroup)
    }

    // MARK: - Layout

    public override func layoutSublayers() {
        super.layoutSublayers()
        layoutDisplayLayers()
        updateVideoRect()
        updateSubtitleViewport()
        updateVideoOutputSize()
    }

    // MARK: - Video output size

    /// Tells ``player`` the size of the picture in the screen's pixels whenever it changes: the track selection can
    /// limit the video it loads to it. A picture that fills the layer counts whole, cropped parts too.
    private func updateVideoOutputSize() {
        guard let player = _player else { return }
        let picture = videoGravity == .resizeAspectFill && !videoRect.isEmpty ? videoRect.size : bounds.size
        let size = picture.width > 0 && picture.height > 0
            ? CGSize(
                width: (picture.width * displayScale).rounded(.up),
                height: (picture.height * displayScale).rounded(.up)
            )
            : nil
        guard size != reportedVideoOutputSize else { return }
        reportedVideoOutputSize = size
        player.setVideoOutputSize(size, for: self)
    }

    private func layoutDisplayLayers() {
        let resize = resizeAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pictureFrame = displayLayerFrame(in: bounds)
        for displayLayer in displayLayers {
            if displayLayer is AVSampleBufferDisplayLayer {
                displayLayer.frame = pictureFrame
                if let animation = resize?.picture {
                    displayLayer.add(animation, forKey: "SEPlayerLayer.resize")
                }
            } else {
                displayLayer.frame = bounds
                if let animation = resize?.bounds {
                    displayLayer.add(animation, forKey: "SEPlayerLayer.resize")
                }
            }
        }
        holdUpcomingSize(in: displayLayers)
        // The subtitles are drawn in the picture, so they move and scale with it.
        subtitleLayer.frame = bounds
        if subtitleLayer.contentsScale != displayScale {
            subtitleLayer.contentsScale = displayScale
            subtitleLayer.setNeedsDisplay()
        }
        if let animation = resize?.bounds {
            subtitleLayer.add(animation, forKey: "SEPlayerLayer.resize")
        }
        CATransaction.commit()
    }

    /// Gives the display layers the frame of the picture at once, as a new gravity or video size does.
    private func layoutDisplayLayerFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pictureFrame = displayLayerFrame(in: bounds)
        let resize = resizeAnimations()
        for displayLayer in displayLayers {
            if displayLayer is AVSampleBufferDisplayLayer {
                displayLayer.frame = pictureFrame
                if let animation = resize?.picture {
                    displayLayer.add(animation, forKey: "SEPlayerLayer.resize")
                }
            } else {
                displayLayer.contentsGravity = Self.contentsGravity(for: videoGravity)
            }
        }
        holdUpcomingSize(in: displayLayers)
        if let animation = resize?.bounds {
            subtitleLayer.add(animation, forKey: "SEPlayerLayer.resize")
        }
        CATransaction.commit()
    }

    private static let holdAnimationKey = "SEPlayerLayer.upcomingSize"

    /// Keeps the frames on screen in the picture of ``presentationSize`` while the display layers already have the
    /// frame of the upcoming size, until the host time of that size. The render server ends it, together with the
    /// first frame of the new size.
    private func holdUpcomingSize(in layers: [CALayer]) {
        // Image queue layers show each frame in its shape already.
        let layers = layers.filter { $0 is AVSampleBufferDisplayLayer }
        guard let upcoming = upcomingSize, !layers.isEmpty else { return }
        let now = CACurrentMediaTime()
        let frame = displayLayerFrame(in: bounds)
        let shown = pictureRect(in: bounds)
        let drawn = Self.rectOfFrame(sized: presentationSize, inDisplayLayerAt: frame)
        guard upcoming.hostTime > now, !frame.isEmpty, !shown.isEmpty, !drawn.isEmpty else {
            return
        }

        let value = NSValue(caTransform3D: transform(from: shown, to: drawn, anchor: frame.center))
        let resize = resizeAnimations()?.heldPicture
        for layer in layers {
            let hold = CABasicAnimation(keyPath: "transform")
            hold.fromValue = value
            hold.toValue = value
            hold.beginTime = layer.convertTime(now, from: nil)
            // A standing clock holds until it moves, and the time comes again.
            hold.duration = upcoming.hostTime.isFinite ? upcoming.hostTime - now : 1e7
            if let resize = resize?.copy() as? CABasicAnimation {
                // Override the upcoming picture's resize only until its first frame. The child keeps
                // the parent's rotation clock, including when a hold is retimed partway through it.
                let start = resize.beginTime == 0 ? convertTime(now, from: nil) : resize.beginTime
                resize.beginTime = start - convertTime(now, from: nil)
                resize.fillMode = .both
                resize.isRemovedOnCompletion = false
                let group = CAAnimationGroup()
                group.animations = [resize]
                group.beginTime = hold.beginTime
                group.duration = hold.duration
                layer.add(group, forKey: Self.holdAnimationKey)
            } else {
                layer.add(hold, forKey: Self.holdAnimationKey)
            }
        }
    }

    /// Where a frame of `size` is drawn in a display layer at `frame`, shaped for the size enqueued after it: on a
    /// device it is stretched to the whole layer (``displayLayerGravity``), on the simulator fitted by its aspect
    /// ratio.
    private static func rectOfFrame(sized size: CGSize, inDisplayLayerAt frame: CGRect) -> CGRect {
        #if targetEnvironment(simulator)
        size.width > 0 && size.height > 0 ? AVMakeRect(aspectRatio: size, insideRect: frame) : frame
        #else
        frame
        #endif
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
    ///
    /// - Returns: The upcoming picture's resize, the current picture's resize for subtitles, and a resize that
    ///   keeps the current picture correctly shaped inside the upcoming display frame until the hold ends.
    private func resizeAnimations() -> (picture: CAAnimation, bounds: CAAnimation, heldPicture: CAAnimation)? {
        for key in animationKeys() ?? [] {
            guard
                let animation = animation(forKey: key) as? CABasicAnimation,
                let keyPath = animation.keyPath,
                keyPath == "bounds.size" || keyPath == "bounds",
                let from = size(from: animation.fromValue) else {
                continue
            }

            // Additive animations run from the difference to zero, onto the model value.
            let fromSize = animation.isAdditive
                ? CGSize(width: bounds.width + from.width, height: bounds.height + from.height)
                : from
            guard fromSize.width > 0, fromSize.height > 0, !bounds.isEmpty else {
                return nil
            }

            let oldRect = displayLayerFrame(in: CGRect(origin: bounds.origin, size: fromSize))
            let newRect = displayLayerFrame(in: bounds)
            guard newRect.width > 0, newRect.height > 0 else { return nil }

            let oldBounds = CGRect(origin: bounds.origin, size: fromSize)
            let oldPicture = pictureRect(in: oldBounds)
            let newPicture = pictureRect(in: bounds)
            let drawn = Self.rectOfFrame(sized: presentationSize, inDisplayLayerAt: newRect)
            guard !drawn.isEmpty else { return nil }

            func resize(from: CGRect, to: CGRect, end: CGRect, anchor: CGPoint) -> CAAnimation {
                let resize = animation.copy() as! CABasicAnimation
                resize.keyPath = "transform"
                resize.isAdditive = false
                resize.fromValue = NSValue(caTransform3D: transform(from: from, to: to, anchor: anchor))
                resize.toValue = NSValue(caTransform3D: transform(from: end, to: to, anchor: anchor))
                resize.byValue = nil
                return resize
            }
            return (
                resize(from: oldRect, to: newRect, end: newRect, anchor: newRect.center),
                resize(from: oldPicture, to: newPicture, end: newPicture, anchor: bounds.center),
                resize(from: oldPicture, to: drawn, end: newPicture, anchor: newRect.center)
            )
        }
        return nil
    }

    /// Shows the picture drawn in `newRect` where `oldRect` is, for a layer that transforms around `anchor`: the
    /// middle of its frame.
    private func transform(from oldRect: CGRect, to newRect: CGRect, anchor: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(oldRect.midX - anchor.x, oldRect.midY - anchor.y, 0)
        transform = CATransform3DScale(transform, oldRect.width / newRect.width, oldRect.height / newRect.height, 1)
        return CATransform3DTranslate(transform, anchor.x - newRect.midX, anchor.y - newRect.midY, 0)
    }

    /// The gravity of the display layers, whose frame this layer places with ``videoGravity``.
    ///
    /// A display layer shapes its picture to the last frame enqueued, before the frames of the old size have shown.
    /// On a device each frame is stretched to that picture, so stretching the picture to the frame (`.resize`) puts
    /// the frame back in its shape. The simulator fits each frame in the picture by its aspect ratio instead, and
    /// there filling the frame with the picture (`.resizeAspectFill`) does.
    private static var displayLayerGravity: AVLayerVideoGravity {
        #if targetEnvironment(simulator)
        .resizeAspectFill
        #else
        .resize
        #endif
    }

    private static func contentsGravity(for gravity: AVLayerVideoGravity) -> CALayerContentsGravity {
        switch gravity {
        case .resizeAspectFill: .resizeAspectFill
        case .resize: .resize
        default: .resizeAspect
        }
    }

    /// Where the picture is in `bounds`: the video rect once the video's size is known, the whole
    /// bounds before.
    private func pictureRect(in bounds: CGRect) -> CGRect {
        pictureRect(for: presentationSize, in: bounds)
    }

    /// The frame of the display layers: the picture of the upcoming size while one is held, of the size on screen
    /// otherwise.
    private func displayLayerFrame(in bounds: CGRect) -> CGRect {
        pictureRect(for: upcomingSize?.size ?? presentationSize, in: bounds)
    }

    private func pictureRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        let rect = Self.videoRect(for: size, in: bounds, gravity: videoGravity)
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

    /// The scale of the screen: the layer of a view that doesn't draw keeps a scale of 1, which would blur the text.
    private var displayScale: CGFloat {
        #if canImport(UIKit)
        if let view = delegate as? UIView, view.traitCollection.displayScale > 0 {
            return view.traitCollection.displayScale
        }
        #endif
        return contentsScale
    }

    /// Subtitles go in the visible part of the picture, sized by the picture as the whole video would show in the
    /// bounds: a picture that fills the bounds or is stretched doesn't make them larger.
    private func updateSubtitleViewport() {
        let fitted = presentationSize.width > 0 && presentationSize.height > 0 && !bounds.isEmpty
            ? AVMakeRect(aspectRatio: presentationSize, insideRect: bounds)
            : bounds
        // A stretched picture keeps the subtitles where the whole video would be.
        let picture = videoGravity == .resize ? fitted : pictureRect(in: bounds)
        // Sizes stay relative to the picture; the insets only take room off where the subtitles go.
        subtitleLayer.sizingViewport = fitted
        #if canImport(UIKit)
        subtitleLayer.viewport = picture.inset(by: legibleContentInsets).intersection(bounds)
        #else
        subtitleLayer.viewport = picture.intersection(bounds)
        #endif
    }

    private func setPreventsCapture(_ preventsCapture: Bool, on layer: CALayer) {
        (layer as? AVSampleBufferDisplayLayer)?.preventsCapture = preventsCapture
    }

    private func updateVideoRect() {
        let rect = Self.videoRect(for: presentationSize, in: bounds, gravity: videoGravity)
        if rect != videoRect {
            videoRect = rect
        }
    }

    private static func videoRect(for size: CGSize, in bounds: CGRect, gravity: AVLayerVideoGravity) -> CGRect {
        guard size.width > 0, size.height > 0, !bounds.isEmpty else {
            return .zero
        }

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

@MainActor
private extension SEPlayerLayer {
    func _set(player: SEPlayer?) {
        guard player !== _player else { return }
        let oldPlayer = _player
        _player = nil
        oldPlayer?.removeVideoOutput(self)
        oldPlayer?.delegate.removeDelegate(self)
        setPresentationSize(.zero, at: nil)
        player?.setVideoOutput(self)
        player?.delegate.addDelegate(self)
        subtitleLayer.setCues(player?.currentCues ?? .emptyTimeZero)
        _player = player
        reportedVideoOutputSize = nil
        updateVideoOutputSize()
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

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
