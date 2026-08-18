//
//  VideoSampleBufferRenderersStorage.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 17.01.2026.
//

import AVFoundation
import SEPlayerCommon

final class VideoSampleBufferRenderersStorage: VideoSampleBufferRenderer {
    nonisolated(unsafe) weak var delegate: VideoSampleBufferRendererDelegate? {
        didSet { renderers.forEach { $0.value.delegate = delegate } }
    }

    var isReadyForMoreMediaData: Bool {
        renderers.last?.value.isReadyForMoreMediaData ?? false
    }

    var isReadyForDisplay: Bool {
        renderers.last?.value.isReadyForDisplay ?? false
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        renderers.last?.value.hasSufficientMediaDataForReliablePlaybackStart ?? false
    }

    var requiresFlushToResumeDecoding: Bool {
        renderers.first(where: { $0.value.requiresFlushToResumeDecoding }) != nil
    }

    var hasOutput: Bool { renderers.count != 0 }

    private let queue: Queue
    // TODO: OrderedSet
    private var renderers = [Box]()

    nonisolated(unsafe) var controlTimebase: CMTimebase?
    nonisolated(unsafe) private var presentationTimeExpectation = PresentationTimeExpectation.none
    private var requestOutputCallback: (DispatchQueue, @Sendable () -> Void)?

    init(queue: Queue) throws {
        self.queue = queue

//        controlTimebase = try CMTimebase(sourceClock: .hostTimeClock)
    }

    func addRenderer(_ renderer: VideoSampleBufferRenderer) {
        assert(queue.isCurrent())
        let box = Box(renderer)
        guard renderers.first(where: { $0 == box }) == nil else {
            return
        }

        renderer.delegate = delegate
        renderer.setControlTimebase(controlTimebase)
        renderer.setPresentationTimeExpectation(presentationTimeExpectation)

        renderers.forEach { $0.value.stopRequestingMediaData() }
//        renderers.insert(.init(renderer))
        renderers.append(box)
        if let (queue, callback) = requestOutputCallback {
            renderer.requestMediaDataWhenReady(on: queue, using: callback)
        }
    }

    func removeRenderer(_ renderer: VideoSampleBufferRenderer) {
        assert(queue.isCurrent())
        let box = Box(renderer)
        renderers.removeAll(where: { $0 == box })
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        assert(queue.isCurrent())
        presentationTimeExpectation = expectation
        renderers.forEach { $0.value.setPresentationTimeExpectation(expectation) }
    }

    func setControlTimebase(_ timebase: CMTimebase?) {
        assert(queue.isCurrent())
        self.controlTimebase = timebase
        renderers.forEach { $0.value.setControlTimebase(timebase) }
//        if let timebase {
//            controlTimebase.source = timebase
//            updateControlTimebase(from: timebase)
//            setupTimebaseNotifications(timebase: timebase)
//        } else {
//            controlTimebase.source = CMClock.hostTimeClock
//        }
    }

    func setIsHidden(_ isHidden: Bool) {
        renderers.forEach { $0.value.setIsHidden(isHidden) }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
//        assert(queue.isCurrent())
        renderers.forEach { $0.value.enqueue(sampleBuffer) }
    }

    func flush() {
        assert(queue.isCurrent())
        renderers.forEach { $0.value.flush() }
    }

    func flush(removeImage: Bool) {
        assert(queue.isCurrent())
        renderers.forEach { $0.value.flush(removeImage: removeImage) }
    }

    @available(iOS 17.0, *)
    func flushAsync(removeImage: Bool) async {
        assert(queue.isCurrent())
        for box in renderers {
            await box.value.flushAsync(removeImage: removeImage)
        }
    }

    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void) {
        assert(queue.isCurrent())
        renderers.forEach { $0.value.flush(removeImage: removeImage, completion: completion) }
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
//        assert(self.queue.isCurrent())
        requestOutputCallback = (queue, block)
        renderers.last?.value.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
//        assert(queue.isCurrent())
        requestOutputCallback = nil
        renderers.forEach { $0.value.stopRequestingMediaData() }
    }

//    private func setupTimebaseNotifications(timebase: CMTimebase) {
//        NotificationCenter.default.removeObserver(self)
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(timbasePropertyChanged),
//                                               name: CMTimebase.effectiveRateChanged,
//                                               object: timebase)
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(timbasePropertyChanged),
//                                               name: CMTimebase.timeJumped,
//                                               object: timebase)
//    }
//
//    @objc
//    private func timbasePropertyChanged(_ notification: Notification) {
//        guard CMTimebaseGetTypeID() == CFGetTypeID(notification.object as CFTypeRef) else {
//            return
//        }
//
//        updateControlTimebase(from: notification.object as! CMTimebase)
//    }
//
//    private func updateControlTimebase(from timebase: CMTimebase) {
//        print("👠 RESET TIMEBASE, time = \(timebase.time.microseconds), rate = \(timebase.rate)")
//
//        if timebase.time.microseconds < 1000000000000 {
//            print()
//        }
//        try? controlTimebase.setTime(timebase.time)
//        try? controlTimebase.setRate(timebase.rate)
//    }
}

private extension VideoSampleBufferRenderersStorage {
    struct Box: Hashable {
        let value: VideoSampleBufferRenderer

        init(_ value: VideoSampleBufferRenderer) {
            self.value = value
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(value))
        }

        static func == (lhs: VideoSampleBufferRenderersStorage.Box, rhs: VideoSampleBufferRenderersStorage.Box) -> Bool {
            lhs.value === rhs.value
        }
    }
}
