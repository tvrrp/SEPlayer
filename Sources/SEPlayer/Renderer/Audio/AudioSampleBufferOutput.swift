import AVFoundation

/// Keeps AVFoundation notification delivery and output operations independently testable.
protocol AudioSampleBufferOutput: AnyObject {
    var isAirPlayActive: Bool { get }
    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }
    /// Joins the synchronizer, which starts and stops the output; only an `AVSampleBufferRenderSynchronizer` takes it.
    func attach(to synchronizer: any PlaybackSynchronizer)
    func detach(from synchronizer: any PlaybackSynchronizer)
    func observeEvents(_ callback: @escaping @Sendable (AudioOutputEvent) -> Void)
    func stopObserving()
    func enqueue(_ buffer: CMSampleBuffer) throws
    func flush()
    func requestMediaDataWhenReady(on queue: DispatchQueue, using callback: @escaping @Sendable () -> Void)
    func stopRequestingMediaData()
    func setVolume(_ volume: Float, isMuted: Bool)
}

extension AudioSampleBufferOutput {
    func setVolume(_ volume: Float, isMuted: Bool) {}
}

enum AudioOutputEvent {
    case recovery(RendererRecoveryReason, Error?)
    /// An automatic flush; `time` is the first flushed timestamp, or `.invalid` when not reported.
    case flushedAutomatically(at: CMTime)
    case failure(Error)
}

final class AVFAudioSampleBufferOutput: AudioSampleBufferOutput {
    private let renderer: AVSampleBufferAudioRenderer
    private var observations: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    var isAirPlayActive: Bool { AudioRoute.isAirPlay }
    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { renderer.hasSufficientMediaDataForReliablePlaybackStart }

    init() {
        renderer = AVSampleBufferAudioRenderer()
    }

    func attach(to synchronizer: any PlaybackSynchronizer) {
        (synchronizer as? AVSampleBufferRenderSynchronizer)?.addRenderer(renderer)
    }

    func detach(from synchronizer: any PlaybackSynchronizer) {
        (synchronizer as? AVSampleBufferRenderSynchronizer)?.removeRenderer(renderer, at: .invalid)
    }

    func setVolume(_ volume: Float, isMuted: Bool) {
        renderer.volume = volume
        renderer.isMuted = isMuted
    }

    func observeEvents(_ callback: @escaping @Sendable (AudioOutputEvent) -> Void) {
        stopObserving()
        let center = NotificationCenter.default
        observations.append(center.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil
        ) { notification in
            let time = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            callback(.flushedAutomatically(at: time ?? .invalid))
        })
        observations.append(center.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: renderer, queue: nil
        ) { _ in
            callback(.recovery(.outputConfigurationChanged, nil))
        })
        statusObservation = renderer.observe(\.status) { renderer, _ in
            guard renderer.status == .failed, let error = renderer.error else {
                return
            }
            let nsError = error as NSError
            if nsError.domain == AVFoundationErrorDomain, nsError.code == AVError.mediaServicesWereReset.rawValue {
                callback(.recovery(.mediaServicesWereReset, error))
            } else {
                callback(.failure(error))
            }
        }
    }

    func stopObserving() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        statusObservation = nil
    }

    deinit { stopObserving() }
    func enqueue(_ buffer: CMSampleBuffer) throws { renderer.enqueue(buffer) }
    func flush() { renderer.flush() }
    func requestMediaDataWhenReady(on queue: DispatchQueue, using callback: @escaping @Sendable () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: callback)
    }

    func stopRequestingMediaData() { renderer.stopRequestingMediaData() }
}
