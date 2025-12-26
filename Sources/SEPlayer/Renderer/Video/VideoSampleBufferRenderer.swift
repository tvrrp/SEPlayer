//
//  VideoSampleBufferRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.12.2025.
//

import AVFoundation

protocol VideoSampleBufferRendererDelegate: AnyObject {
    func renderer(_ renderer: VideoSampleBufferRenderer, didFailedRenderingWith error: Error?)
}

protocol VideoSampleBufferRenderer: VideoSampleBufferRendererPerformance {
    var delegate: VideoSampleBufferRendererDelegate? { get set }
    var timebase: CMTimebase { get }
    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }

    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func flush(removeImage: Bool)
    @available(iOS 17.0, *)
    func flush(removeImage: Bool) async
    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void)
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
    func stopRequestingMediaData()
}

protocol VideoSampleBufferRendererPerformance: AnyObject {
    @available(iOS 17.4, *)
    var presentationTimeExpectation: AVSampleBufferVideoRenderer.PresentationTimeExpectation { get set }
}

private final class WeakBox {
    weak var value: VideoSampleBufferRenderer?
    init(_ value: VideoSampleBufferRenderer) { self.value = value }
}

private enum AssocKeys {
    static var service: UInt8 = 0
}

extension AVSampleBufferDisplayLayer {
    func createRenderer() -> VideoSampleBufferRenderer {
        if let box = objc_getAssociatedObject(self, &AssocKeys.service),
           let service = (box as? WeakBox)?.value {
            return service
        }

        let service: VideoSampleBufferRenderer = if #available(iOS 17, *) {
            AVSBVideoRenderer(renderer: self.sampleBufferRenderer)
        } else {
            AVSBDLVideoRenderer(layer: self)
        }

        let weakBox = WeakBox(service)
        objc_setAssociatedObject(self, &AssocKeys.service, weakBox, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return service
    }
}

@available(iOS 17.0, *)
final class AVSBVideoRenderer: VideoSampleBufferRenderer {
    weak var delegate: VideoSampleBufferRendererDelegate?

    var timebase: CMTimebase { renderer.timebase }
    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        renderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    @available(iOS 17.4, *)
    var presentationTimeExpectation: AVSampleBufferVideoRenderer.PresentationTimeExpectation {
        get { .none }
        set { renderer.presentationTimeExpectation = newValue }
    }

    private let renderer: AVSampleBufferVideoRenderer
    private var observer: NSKeyValueObservation?

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer

        observer = renderer.observe(\.status) { [weak self] renderer, _ in
            guard let self else { return }
            if renderer.status == .failed {
                delegate?.renderer(self, didFailedRenderingWith: renderer.error)
            }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    func flush() {
        renderer.flush()
    }

    func flush(removeImage: Bool) {
        renderer.flush(removingDisplayedImage: removeImage)
    }

    func flush(removeImage: Bool) async {
        await renderer.flush(removingDisplayedImage: removeImage)
    }

    func flush(removeImage: Bool, completion: @escaping () -> Void) {
        renderer.flush(removingDisplayedImage: removeImage, completionHandler: completion)
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        renderer.stopRequestingMediaData()
    }
}

final class AVSBDLVideoRenderer: VideoSampleBufferRenderer {
    weak var delegate: VideoSampleBufferRendererDelegate?

    var timebase: CMTimebase {
        queue.sync { layer.timebase }
    }

    var isReadyForMoreMediaData: Bool {
        queue.sync { layer.isReadyForMoreMediaData }
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        queue.sync { layer.hasSufficientMediaDataForReliablePlaybackStart }
    }

    @available(iOS 17.4, *)
    var presentationTimeExpectation: AVSampleBufferVideoRenderer.PresentationTimeExpectation {
        get {
            assertionFailure("iOS 17 must use AVSBVideoRenderer")
            return .none
        }
        set {
            assertionFailure("iOS 17 must use AVSBVideoRenderer")
        }
    }

    private let layer: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue.main
    private var observer: NSKeyValueObservation?

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer

        queue.async { [self] in
            observer = layer.observe(\.status) { [weak self] layer, _ in
                guard let self else { return }
                if layer.status == .failed {
                    delegate?.renderer(self, didFailedRenderingWith: layer.error)
                }
            }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            self.layer.enqueue(sampleBuffer)
        }
    }

    func flush() {
        queue.async {
            self.layer.flush()
        }
    }

    func flush(removeImage: Bool) {
        queue.async {
            if removeImage {
                self.layer.flushAndRemoveImage()
            } else {
                self.layer.flush()
            }
        }
    }

    @available(iOS 17.0, *)
    func flush(removeImage: Bool) async {
        assertionFailure("iOS 17 must use AVSBVideoRenderer")
    }

    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void) {
        assertionFailure("iOS 17 must use AVSBVideoRenderer")
        completion()
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping () -> Void) {
        queue.async {
            self.layer.requestMediaDataWhenReady(on: queue, using: block)
        }
    }

    func stopRequestingMediaData() {
        queue.async {
            self.layer.stopRequestingMediaData()
        }
    }
}
