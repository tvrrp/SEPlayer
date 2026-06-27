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
        renderers.allSatisfy(\.value.isReadyForMoreMediaData)
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        renderers.allSatisfy(\.value.hasSufficientMediaDataForReliablePlaybackStart)
    }

    var hasOutput: Bool { renderers.count != 0 }

    private let queue: Queue
    private var renderers = Set<Box>()

    nonisolated(unsafe) var controlTimebase: CMTimebase?
    nonisolated(unsafe) private var presentationTimeExpectation = PresentationTimeExpectation.none

    init(queue: Queue) throws {
        self.queue = queue

//        controlTimebase = try CMTimebase(sourceClock: .hostTimeClock)
    }

    func addRenderer(_ renderer: VideoSampleBufferRenderer) {
        assert(queue.isCurrent())
        renderers.insert(.init(renderer))
        renderer.delegate = delegate
        renderer.setControlTimebase(controlTimebase)
        renderer.setPresentationTimeExpectation(presentationTimeExpectation)
    }

    func removeRenderer(_ renderer: VideoSampleBufferRenderer) {
        assert(queue.isCurrent())
        renderers.remove(.init(renderer))
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
        renderers.forEach { $0.value.requestMediaDataWhenReady(on: queue, using: block) }
    }

    func stopRequestingMediaData() {
//        assert(queue.isCurrent())
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
