//
//  VideoSampleBufferRenderersStorage.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 17.01.2026.
//

import AVFoundation

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

    private let queue: Queue
    nonisolated(unsafe) private let renderersStorage = NSHashTable<AnyObject>()

    init(queue: Queue) {
        self.queue = queue
    }

    func addRenderer(_ renderer: VideoSampleBufferRenderer) {
        assert(queue.isCurrent())
        renderersStorage.add(renderer)
    }

    func removeRenderer(_ renderer: VideoSampleBufferRenderer) {
        assert(queue.isCurrent())
        renderersStorage.remove(renderer)
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        assert(queue.isCurrent())
        renderers.forEach { $0.setPresentationTimeExpectation(expectation) }
    }

    func setControlTimebase(_ timebase: TimebaseSource?) {
        assert(queue.isCurrent())
        renderers.forEach { $0.setControlTimebase(timebase) }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        assert(queue.isCurrent())
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
        assert(self.queue.isCurrent())
        renderers.forEach { $0.requestMediaDataWhenReady(on: queue, using: block) }
    }

    func stopRequestingMediaData() {
        assert(queue.isCurrent())
        renderers.forEach { $0.stopRequestingMediaData() }
    }
}
