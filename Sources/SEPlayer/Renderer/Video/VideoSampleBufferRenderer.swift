//
//  VideoSampleBufferRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.12.2025.
//

import AVFoundation
import SEPlayerCommon

public protocol VideoSampleBufferRendererDelegate: AnyObject {
    nonisolated var isolation: any Actor { get }
    func renderer(_ renderer: VideoSampleBufferRenderer, didFailedRenderingWith error: Error, isolation: isolated any Actor)
    func renderer(_ renderer: VideoSampleBufferRenderer, didChangeReadyForDisplay: Bool, isolation: isolated any Actor)
}

public protocol VideoSampleBufferRenderer: VideoSampleBufferRendererPerformance, Sendable {
    nonisolated var delegate: VideoSampleBufferRendererDelegate? { get set }
    var isReadyForDisplay: Bool { get }
    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }
    var requiresFlushToResumeDecoding: Bool { get }

    func setIsHidden(_ isHidden: Bool)
    func setControlTimebase(_ timebase: CMTimebase?)
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func flush(removeImage: Bool)
    @available(iOS 17.0, *)
    func flushAsync(removeImage: Bool) async
    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void)
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
    func stopRequestingMediaData()
}

public enum PresentationTimeExpectation {
    case none
    case monotonicallyIncreasing
    case minimumUpcoming(CMTime)
}

public protocol VideoSampleBufferRendererPerformance: AnyObject {
    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation)
}

private final class WeakBox {
    weak var value: VideoSampleBufferRenderer?
    init(_ value: VideoSampleBufferRenderer) { self.value = value }
}

private enum AssocKeys {
    static var service: UInt8 = 0
}

extension AVSampleBufferDisplayLayer {
    @MainActor
    func createRenderer() -> VideoSampleBufferRenderer {
        if let box = objc_getAssociatedObject(self, &AssocKeys.service),
           let service = (box as? WeakBox)?.value {
            return service
        }

        let service: VideoSampleBufferRenderer = if #available(macOS 14.4, iOS 17.4, tvOS 17.4, visionOS 1.1, *) {
            AVSBVideoRenderer(renderer: self.sampleBufferRenderer, layer: self)
        } else {
            AVSBDLVideoRenderer(layer: self)
        }

        let weakBox = WeakBox(service)
        objc_setAssociatedObject(self, &AssocKeys.service, weakBox, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return service
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
//        TODO: think about this
        switch expectation {
        case let .minimumUpcoming(time):
            let selector = NSSelectorFromString("expectMinimumUpcomingSampleBufferPresentationTime:")
            if responds(to: selector) {
                perform(selector, with: time)
            }
        case .monotonicallyIncreasing:
            let selector = NSSelectorFromString("expectMonotonicallyIncreasingUpcomingSampleBufferPresentationTimes")
            if responds(to: selector) {
                perform(selector)
            }
        case .none:
            let selector = NSSelectorFromString("resetUpcomingSampleBufferPresentationTimeExpectations")
            if responds(to: selector) {
                perform(selector)
            }
        }
    }
}

@available(iOS 17.0, *)
final class AVSBVideoRenderer: VideoSampleBufferRenderer {
    nonisolated var delegate: VideoSampleBufferRendererDelegate? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    var timebase: CMTimebase { renderer.timebase }
    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }
    var isReadyForDisplay: Bool {
        if #available(iOS 17.4, macCatalyst 17.4, *) {
            layer.isReadyForDisplay
        } else {
            true
        }
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        renderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    var requiresFlushToResumeDecoding: Bool {
        renderer.requiresFlushToResumeDecoding
    }

    private let lock = UnfairLock()
    private nonisolated(unsafe) let layer: AVSampleBufferDisplayLayer
    private nonisolated(unsafe) let renderer: AVSampleBufferVideoRenderer
    private nonisolated(unsafe) var observer: NSKeyValueObservation? // mutated only on init
    private nonisolated(unsafe) weak var _delegate: VideoSampleBufferRendererDelegate? // guarded by lock

    @MainActor
    init(renderer: AVSampleBufferVideoRenderer, layer: AVSampleBufferDisplayLayer) {
        self.renderer = renderer
        self.layer = layer

        observer = renderer.observe(\.status) { [weak self] renderer, _ in
            guard let self else { return }
            if renderer.status == .failed, let error = renderer.error, let delegate {
                Task {
                    await delegate.renderer(self, didFailedRenderingWith: error, isolation: delegate.isolation)
                }
            }
        }

        if #available(iOS 17.4, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(readyForDisplayDidChange),
                name: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                object: layer
            )
        }
    }

    deinit {
        observer?.invalidate()
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        if #available(macOS 14.4, iOS 17.4, tvOS 17.4, visionOS 1.1, *) {
            switch expectation {
            case .none:
                renderer.presentationTimeExpectation = .none
            case .monotonicallyIncreasing:
                renderer.presentationTimeExpectation = .monotonicallyIncreasing
            case let .minimumUpcoming(time):
                renderer.presentationTimeExpectation = .minimumUpcoming(time)
            }
        } else {
            layer.setPresentationTimeExpectation(expectation)
        }
    }

    func setControlTimebase(_ timebase: CMTimebase?) {
        if layer.controlTimebase !== timebase {
            layer.controlTimebase = timebase
        }
    }

    func setIsHidden(_ isHidden: Bool) {
        DispatchQueue.main.async {
            self.layer.isHidden = isHidden
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

    func flushAsync(removeImage: Bool) async {
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

    @objc
    private func readyForDisplayDidChange() {
        if #available(iOS 17.4, *) {
            Task {
                guard let delegate else { return }
                await delegate.renderer(self, didChangeReadyForDisplay: layer.isReadyForDisplay, isolation: delegate.isolation)
            }
        }
    }
}

final class AVSBDLVideoRenderer: VideoSampleBufferRenderer {
    nonisolated var delegate: VideoSampleBufferRendererDelegate? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    var timebase: CMTimebase? {
        get { nil }
        set { layer.controlTimebase = newValue }
    }

    var isReadyForMoreMediaData: Bool {
        layer.isReadyForMoreMediaData
    }

    var isReadyForDisplay: Bool {
        if #available(iOS 17.4, macCatalyst 17.4, *) {
            layer.isReadyForDisplay
        } else {
            true
        }
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        layer.hasSufficientMediaDataForReliablePlaybackStart
    }

    var requiresFlushToResumeDecoding: Bool {
        layer.requiresFlushToResumeDecoding
    }

    private nonisolated(unsafe) let layer: AVSampleBufferDisplayLayer
    private let lock = UnfairLock()

    private nonisolated(unsafe) var observer: NSKeyValueObservation? // mutated only on init
    private nonisolated(unsafe) weak var _delegate: VideoSampleBufferRendererDelegate? // guarded by lock

    @MainActor
    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer

        DispatchQueue.main.async { [self] in
            observer = layer.observe(\.status) { [weak self] layer, _ in
                guard let self else { return }
                if layer.status == .failed, let error = layer.error, let delegate {
                    Task {
                        await delegate.renderer(self, didFailedRenderingWith: error, isolation: delegate.isolation)
                    }
                }
            }
        }

        if #available(iOS 17.4, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(readyForDisplayDidChange),
                name: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                object: layer
            )
        }
    }

    deinit {
        observer?.invalidate()
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        layer.setPresentationTimeExpectation(expectation)
    }

    func setControlTimebase(_ timebase: CMTimebase?) {
        if layer.controlTimebase !== timebase {
            layer.controlTimebase = timebase
        }
    }

    func setIsHidden(_ isHidden: Bool) {
        DispatchQueue.main.async {
            self.layer.isHidden = isHidden
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        layer.enqueue(sampleBuffer)
    }

    func flush() {
        layer.flush()
    }

    func flush(removeImage: Bool) {
        if removeImage {
            layer.flushAndRemoveImage()
        } else {
            layer.flush()
        }
    }

    @available(iOS 17.0, *)
    func flushAsync(removeImage: Bool) async {
        if removeImage {
            await layer.flushAndRemoveImage()
        } else {
            await layer.flush()
        }
    }

    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void) {
        if removeImage {
            self.layer.flushAndRemoveImage()
        } else {
            self.layer.flush()
        }
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping () -> Void) {
        layer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        layer.stopRequestingMediaData()
    }

    @objc
    private func readyForDisplayDidChange() {
        if #available(iOS 17.4, *) {
            Task {
                guard let delegate else { return }
                await delegate.renderer(self, didChangeReadyForDisplay: layer.isReadyForDisplay, isolation: delegate.isolation)
            }
        }
    }
}
