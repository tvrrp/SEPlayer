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
        didSet { renderers.forEach { $0.delegate = delegate } }
    }

    var isReadyForMoreMediaData: Bool {
        renderers.allSatisfy(\.isReadyForMoreMediaData)
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        renderers.allSatisfy(\.hasSufficientMediaDataForReliablePlaybackStart)
    }

    var hasOutput: Bool { renderersStorage.count != 0 }

    private var renderers: [VideoSampleBufferRenderer] {
        renderersStorage.allObjects as! [VideoSampleBufferRenderer]
    }

    nonisolated(unsafe) var controlTimebase: CMTimebase
    nonisolated(unsafe) private var presentationTimeExpectation = PresentationTimeExpectation.none

    private let queue: Queue
    nonisolated(unsafe) private let renderersStorage = NSHashTable<AnyObject>()

    init(queue: Queue) throws {
        self.queue = queue

        controlTimebase = try CMTimebase(sourceClock: .hostTimeClock)
    }

    func addRenderer(_ renderer: VideoSampleBufferRenderer) {
        assert(queue.isCurrent())
        renderersStorage.add(renderer)
        renderer.delegate = delegate
        renderer.setControlTimebase(controlTimebase)
        renderer.setPresentationTimeExpectation(presentationTimeExpectation)
    }

    func removeRenderer(_ renderer: VideoSampleBufferRenderer) {
        assert(queue.isCurrent())
        renderersStorage.remove(renderer)
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        assert(queue.isCurrent())
        presentationTimeExpectation = expectation
        renderers.forEach { $0.setPresentationTimeExpectation(expectation) }
    }

    func setControlTimebase(_ timebase: CMTimebase?) {
        assert(queue.isCurrent())
        if let timebase {
            controlTimebase.source = timebase
            updateControlTimebase(from: timebase)
            setupTimebaseNotifications(timebase: timebase)
        } else {
            controlTimebase.source = CMClock.hostTimeClock
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
//        assert(queue.isCurrent())
        renderers.forEach { $0.enqueue(sampleBuffer) }
    }

    func flush() {
        assert(queue.isCurrent())
        renderers.forEach { $0.flush() }
    }

    func flush(removeImage: Bool) {
        assert(queue.isCurrent())
        renderers.forEach { $0.flush(removeImage: removeImage) }
    }

    @available(iOS 17.0, *)
    func flushAsync(removeImage: Bool) async {
        assert(queue.isCurrent())
        for renderer in renderers {
            await renderer.flushAsync(removeImage: removeImage)
        }
    }

    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void) {
        assert(queue.isCurrent())
        renderers.forEach { $0.flush(removeImage: removeImage, completion: completion) }
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
//        assert(self.queue.isCurrent())
        renderers.forEach { $0.requestMediaDataWhenReady(on: queue, using: block) }
    }

    func stopRequestingMediaData() {
//        assert(queue.isCurrent())
        renderers.forEach { $0.stopRequestingMediaData() }
    }

    private func setupTimebaseNotifications(timebase: CMTimebase) {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(timbasePropertyChanged),
                                               name: CMTimebase.effectiveRateChanged,
                                               object: timebase)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(timbasePropertyChanged),
                                               name: CMTimebase.timeJumped,
                                               object: timebase)
    }

    @objc
    private func timbasePropertyChanged(_ notification: Notification) {
        guard CMTimebaseGetTypeID() == CFGetTypeID(notification.object as CFTypeRef) else {
            return
        }

        updateControlTimebase(from: notification.object as! CMTimebase)
    }

    private func updateControlTimebase(from timebase: CMTimebase) {
        print("👠 RESET TIMEBASE, time = \(timebase.time.microseconds), rate = \(timebase.rate)")

        if timebase.time.microseconds < 1000000000000 {
            print()
        }
        try? controlTimebase.setTime(timebase.time)
        try? controlTimebase.setRate(timebase.rate)
    }
}
