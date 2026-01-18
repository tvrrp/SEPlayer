//
//  VideoSampleBufferRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.12.2025.
//

import AVFoundation

public protocol VideoSampleBufferRendererDelegate: AnyObject {
    nonisolated var isolation: any Actor { get }
    func renderer(_ renderer: VideoSampleBufferRenderer, didFailedRenderingWith error: Error?, isolation: isolated any Actor)
}

public protocol VideoSampleBufferRenderer: VideoSampleBufferRendererPerformance, Sendable {
    nonisolated var delegate: VideoSampleBufferRendererDelegate? { get set }
    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }

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

        let service: VideoSampleBufferRenderer = if #available(iOS 17, *) {
            AVSBVideoRenderer(renderer: self.sampleBufferRenderer, layer: self)
        } else {
            AVSBDLVideoRenderer(layer: self)
        }

        let weakBox = WeakBox(service)
        objc_setAssociatedObject(self, &AssocKeys.service, weakBox, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return service
    }

    @MainActor
    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
//        TODO: think about this
//        switch expectation {
//        case let .minimumUpcoming(time):
//            let selector = Selector("expectMinimumUpcomingSampleBufferPresentationTime:")
//            if responds(to: selector) {
//                perform(selector, with: time)
//            }
//        case .monotonicallyIncreasing:
//            let selector = Selector("expectMonotonicallyIncreasingUpcomingSampleBufferPresentationTimes")
//            if responds(to: selector) {
//                perform(selector)
//            }
//        case .none:
//            let selector = Selector("resetUpcomingSampleBufferPresentationTimeExpectations")
//            if responds(to: selector) {
//                perform(selector)
//            }
//        }
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
    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        renderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    private let lock = UnfairLock()
    @MainActor private let layer: AVSampleBufferDisplayLayer
    private nonisolated(unsafe) let renderer: AVSampleBufferVideoRenderer
    private nonisolated(unsafe) var observer: NSKeyValueObservation? // mutated only on init
    private nonisolated(unsafe) weak var _delegate: VideoSampleBufferRendererDelegate? // guarded by lock

    @MainActor
    init(renderer: AVSampleBufferVideoRenderer, layer: AVSampleBufferDisplayLayer) {
        self.renderer = renderer
        self.layer = layer

        observer = renderer.observe(\.status) { [weak self] renderer, _ in
            guard let self else { return }
            if renderer.status == .failed, let delegate {
                Task {
                    await delegate.renderer(self, didFailedRenderingWith: renderer.error, isolation: delegate.isolation)
                }
            }
        }
    }

    deinit {
        observer?.invalidate()
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        if #available(iOS 17.4, *) {
            switch expectation {
            case .none:
                renderer.presentationTimeExpectation = .none
            case .monotonicallyIncreasing:
                renderer.presentationTimeExpectation = .monotonicallyIncreasing
            case let .minimumUpcoming(time):
                renderer.presentationTimeExpectation = .minimumUpcoming(time)
            }
        } else {
            DispatchQueue.main.async {
                self.layer.setPresentationTimeExpectation(expectation)
            }
        }
    }

    func setControlTimebase(_ timebase: CMTimebase?) {
        DispatchQueue.main.async {
            self.layer.controlTimebase = timebase
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
}

final class AVSBDLVideoRenderer: VideoSampleBufferRenderer {
    nonisolated var delegate: VideoSampleBufferRendererDelegate? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    var timebase: CMTimebase? {
        get { nil }
        set { DispatchQueue.main.async { self.layer.controlTimebase = newValue } }
    }

    var isReadyForMoreMediaData: Bool {
        lock.withLock { _isReadyForMoreMediaData }
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        DispatchQueue.main.sync { self.layer.hasSufficientMediaDataForReliablePlaybackStart }
    }

    @MainActor private let layer: AVSampleBufferDisplayLayer
    private let lock = UnfairLock()

    private nonisolated(unsafe) var observer: NSKeyValueObservation? // mutated only on init
    private nonisolated(unsafe) weak var _delegate: VideoSampleBufferRendererDelegate? // guarded by lock
    private nonisolated(unsafe) var _isReadyForMoreMediaData = true // guarded by lock
    @MainActor private var requestMediaDataInfo: (DispatchQueue, () -> Void)?

    @MainActor
    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer

        DispatchQueue.main.async { [self] in
            observer = layer.observe(\.status) { [weak self] layer, _ in
                guard let self else { return }
                if layer.status == .failed, let delegate {
                    let error = layer.error

                    Task {
                        await delegate.renderer(self, didFailedRenderingWith: error, isolation: delegate.isolation)
                    }
                }
            }

            registerForReadyNotifications()
        }
    }

    deinit {
        observer?.invalidate()
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        DispatchQueue.main.async { self.layer.setPresentationTimeExpectation(expectation) }
    }

    func setControlTimebase(_ timebase: CMTimebase?) {
        DispatchQueue.main.async {
            self.layer.controlTimebase = timebase
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async { [self] in
            layer.enqueue(sampleBuffer)
            let isReadyForMoreMediaData = layer.isReadyForMoreMediaData
            lock.withLock { _isReadyForMoreMediaData = isReadyForMoreMediaData }

            if !isReadyForMoreMediaData {
                registerForReadyNotifications()
            }
        }
    }

    func flush() {
        DispatchQueue.main.async {
            self.layer.flush()
            self.setPresentationTimeExpectation(.none)
        }
    }

    func flush(removeImage: Bool) {
        DispatchQueue.main.async { [self] in
            if removeImage {
                layer.flushAndRemoveImage()
            } else {
                layer.flush()
            }

            setPresentationTimeExpectation(.none)
        }
    }

    @available(iOS 17.0, *)
    func flushAsync(removeImage: Bool) async {
        await MainActor.run {
            if removeImage {
                layer.flushAndRemoveImage()
            } else {
                layer.flush()
            }

            setPresentationTimeExpectation(.none)
        }
    }

    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void) {
        Task { @MainActor in
            if removeImage {
                self.layer.flushAndRemoveImage()
            } else {
                self.layer.flush()
            }

            completion()
            setPresentationTimeExpectation(.none)
        }
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.requestMediaDataInfo = (queue, block)
        }
    }

    func stopRequestingMediaData() {
        DispatchQueue.main.async { self.requestMediaDataInfo = nil }
    }

    @MainActor
    private func registerForReadyNotifications() {
        layer.requestMediaDataWhenReady(on: .main) { [weak self] in
            guard let self else { return }

            MainActor.assumeIsolated {
                self.layer.stopRequestingMediaData()

                self.lock.withLock {
                    self._isReadyForMoreMediaData = self.layer.isReadyForMoreMediaData
                }

                if let (queue, block) = self.requestMediaDataInfo {
                    queue.async { block() }
                }
            }
        }
    }
}
