//
//  TestAudioSink.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.07.2025.
//

import AVFoundation

final class TestAudioSink: IAudioSink {
    func configure(inputFormat: AudioStreamBasicDescription, channelLayout: ManagedAudioChannelLayout?) throws {
//        let session = AVAudioSession.sharedInstance()
//        let maxChannels = session.maximumOutputNumberOfChannels
//        let prefChannels = min(maxChannels, Int(inputFormat.mChannelsPerFrame))
//        try! session.setPreferredOutputNumberOfChannels(prefChannels)
    }

    weak var delegate: (any AudioSinkDelegate)?

    var timebase: CMTimebase? {
        renderSynchronizer.timebase
    }

    var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = newValue }
    }

    private let queue: Queue
    private let renderSynchronizer: AVSampleBufferRenderSynchronizer
    private let audioRenderer: AVSampleBufferAudioRenderer
    private var playbackParameters: PlaybackParameters = .default

    private var resetTime = Int64.timeUnset
    private var isPlaying = false
    private var didHandleEndOfStream = false

    private var blockWork: (() -> Void)?
    private var blockQueue: Queue?
    private var pendingFlushError: Error?

    init(
        queue: Queue,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) {
        self.queue = queue
        self.renderSynchronizer = renderSynchronizer

        audioRenderer = AVSampleBufferAudioRenderer()
        renderSynchronizer.addRenderer(audioRenderer)
        renderSynchronizer.delaysRateChangeUntilHasSufficientMediaData = false

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didRecieve), name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: nil)
        center.addObserver(self, selector: #selector(didRecieve), name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: nil)
    }

    func requestMediaDataWhenReady(on queue: Queue, block: @escaping () -> Void) {
        blockWork = block
        blockQueue = queue

        audioRenderer.requestMediaDataWhenReady(on: self.queue.queue) { [weak self] in
            let blockWork = self?.blockWork

            self?.blockQueue?.async { blockWork?() }
        }
    }

    func stopRequestingMediaData() {
        blockWork = nil
        blockQueue = nil
        audioRenderer.stopRequestingMediaData()
    }

    func getPosition() -> Int64? {
        guard resetTime != .timeUnset else { return nil }
        return renderSynchronizer.currentTime().microseconds
    }

    func play() {
        isPlaying = true
        renderSynchronizer.setRate(playbackParameters.playbackRate, time: .from(microseconds: resetTime))
    }

    func pause() {
        isPlaying = false
        renderSynchronizer.rate = .zero
    }

    func handleDiscontinuity() {
        
    }

    func handleBuffer(_ buffer: CMSampleBuffer, presentationTime: Int64) throws -> Bool {
        if let pendingFlushError {
            self.pendingFlushError = nil
            throw pendingFlushError
        }

        guard audioRenderer.isReadyForMoreMediaData else { return false }

        if resetTime == .timeUnset {
            print("🧚 reset time = \(presentationTime)")
            resetTime = presentationTime
            if isPlaying {
                play()
            }
        }

        audioRenderer.enqueue(buffer)
        return true
    }

    func playToEndOfStream() throws {
//        audioRenderer.flush(fromSourceTime: /*<#T##CMTime#>*/)
    }

    func isEnded() -> Bool {
        return true
    }

    func hasPendingData() -> Bool {
        resetTime != .timeUnset && audioRenderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        self.playbackParameters = playbackParameters
        if isPlaying {
            renderSynchronizer.rate = playbackParameters.playbackRate
        }
    }

    func getPlaybackParameters() -> PlaybackParameters {
        playbackParameters
    }

    func flush(reuse: Bool) {
        print("🧚 FLUSH")
//        print("🧚 FLUSH")
//        print("🧚 FLUSH")
        delegate?.onPositionDiscontinuity()
        renderSynchronizer.rate = .zero
        resetTime = .timeUnset
        audioRenderer.flush()
    }

    func reset() {
        delegate?.onPositionDiscontinuity()
        renderSynchronizer.rate = .zero
        resetTime = .timeUnset
        audioRenderer.flush()
    }

    @objc private func didRecieve(notification: NSNotification) {
        queue.async { [self] in
            delegate?.onPositionDiscontinuity()
            pendingFlushError = ErrorBuilder(errorDescription: "")

            let blockWork = blockWork
            blockQueue?.async { blockWork }
        }
    }
}
