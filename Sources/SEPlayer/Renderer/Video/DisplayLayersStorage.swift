//
//  DisplayLayersStorage.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 17.01.2026.
//

import AVFoundation
import SEPlayerCommon

/// The display layers of the video renderer.
///
/// Every output gets its own `AVSampleBufferDisplayLayer`, and all of them get the same samples.
/// The layers showing one video form a `LayerSet`. A set always has at least one layer: with no
/// outputs, one layer keeps running off-screen, and the first output to arrive takes it.
///
/// `AVSampleBufferDisplayLayer` does not handle aspect ratio changes, so a sample with a new
/// aspect ratio starts a new set. Its layers get the new video off-screen, while the old set keeps
/// showing the old one. A timer on the control timebase fires at the time of the first new sample,
/// and the new layers replace the old ones at once, without animation.
///
/// Layers are made on the main queue, ahead of time: an `AVSampleBufferDisplayLayer` made on
/// another thread and fed at once can fail to decode every frame after its first keyframe.
///
/// Runs on the player queue; changes to the layer tree go to the main queue.
final class DisplayLayersStorage {
    weak var delegate: VideoSampleBufferRendererDelegate? {
        didSet { allLayers.forEach { $0.renderer.delegate = delegate } }
    }

    var isReadyForMoreMediaData: Bool { leadRenderer.isReadyForMoreMediaData }

    /// Whether the layers can show a frame. Also true while the video is still ahead of the current
    /// time, as at a paused item boundary: nothing is due yet, and waiting for a frame would keep
    /// playback from starting. After a seek the decoder starts from a keyframe at or before the
    /// seek position, so there the frame at the position is waited for.
    var isReadyForDisplay: Bool {
        if leadRenderer.isReadyForDisplay { return true }
        guard let firstSampleTime = current.firstSampleTime, let controlTimebase else { return false }
        return firstSampleTime > controlTimebase.time
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        leadRenderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    private let queue: any Queue
    private let switchTimer: DispatchSourceTimer
    /// When the pending switch shows the new set.
    private var switchTime: CMTime?
    private var timeJumpObserver: NSObjectProtocol?

    /// The set that gets the samples.
    private var current: LayerSet
    /// The set still on screen until `current` reaches its first sample.
    private var previous: LayerSet?
    private var controlTimebase: CMTimebase?
    /// Layers made on the main queue, ready for the next set or output.
    private var spareLayers: [AVSampleBufferDisplayLayer] = []
    private var isMakingSpareLayer = false
    private var mediaDataRequest: (queue: DispatchQueue, block: @Sendable () -> Void)?

    /// All layers of a set get the same samples, so the first one speaks for all of them.
    private var leadRenderer: VideoSampleBufferRenderer { current.layers[0].renderer }

    private var allLayers: [DisplayLayer] {
        current.layers + (previous?.layers ?? [])
    }

    /// Made where the player is made, normally on the main queue.
    init(queue: any Queue) {
        self.queue = queue
        current = LayerSet(layers: [DisplayLayer(layer: AVSampleBufferDisplayLayer(), controlTimebase: nil, delegate: nil)])
        switchTimer = DispatchSource.makeTimerSource(queue: queue.queue)
        switchTimer.setEventHandler { [weak self] in
            self?.finishSwitch()
        }
        switchTimer.activate()
        queue.justDispatch { [weak self] in self?.makeSpareLayersIfNeeded() }
    }

    deinit {
        timeJumpObserver.map(NotificationCenter.default.removeObserver)
        switchTimer.cancel()
    }

    // MARK: - Outputs

    func addOutput(_ output: VideoOutput) {
        assert(queue.isCurrent())
        guard !current.layers.contains(where: { $0.output === output }) else { return }

        // While a switch is pending, the output needs a layer in both sets.
        if let previous {
            add(output, to: previous)
        }
        add(output, to: current)
    }

    func removeOutput(_ output: VideoOutput) {
        assert(queue.isCurrent())

        for set in [current, previous].compactMap({ $0 }) {
            guard let displayLayer = set.layers.first(where: { $0.output === output }) else { continue }

            displayLayer.output = nil
            hide(displayLayer.layer, from: output)

            // The last layer of a set stays, off-screen, so the renderer keeps running.
            if set.layers.count > 1 {
                displayLayer.renderer.stopRequestingMediaData()
                set.layers.removeAll { $0 === displayLayer }
            }
        }

        restartMediaDataRequest()
    }

    private func add(_ output: VideoOutput, to set: LayerSet) {
        let displayLayer: DisplayLayer
        if let unused = set.layers.first(where: { $0.output == nil }) {
            // A layer without an output, off-screen or left by a gone view, is taken as it is.
            displayLayer = unused
        } else {
            displayLayer = makeDisplayLayer()
            set.history.forEach { displayLayer.renderer.enqueue($0) }
            set.layers.append(displayLayer)
        }
        displayLayer.output = output

        // The layers of a pending switch go on screen when it finishes.
        if set !== current || previous == nil {
            show(displayLayer.layer, in: output, presentationSize: set.presentationSize)
        }
    }

    // MARK: - Samples

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if let presentationSize = sampleBuffer.presentationSize {
            if let currentAspectRatio = current.aspectRatio,
               abs(currentAspectRatio - presentationSize.aspectRatio) > 0.01 {
                startSwitch(presentationSize: presentationSize, at: sampleBuffer.outputPresentationTimeStamp)
            } else if current.presentationSize != presentationSize {
                current.presentationSize = presentationSize
                // A pending switch tells the outputs when it finishes.
                if previous == nil {
                    announcePresentationSize(presentationSize, to: current.layers.compactMap(\.output))
                }
            }
        }

        if current.firstSampleTime == nil, sampleBuffer.numSamples > 0 {
            current.firstSampleTime = sampleBuffer.outputPresentationTimeStamp
        }

        current.layers.forEach { $0.renderer.enqueue(sampleBuffer) }
        current.history.append(sampleBuffer)
        trimHistory(of: current)
    }

    func flush(removeImage: Bool = false) {
        assert(queue.isCurrent())
        finishSwitch()
        current.layers.forEach { $0.renderer.flush(removeImage: removeImage) }
        current.history.removeAll()
        current.firstSampleTime = nil
    }

    func setControlTimebase(_ timebase: CMTimebase?) {
        assert(queue.isCurrent())
        guard timebase !== controlTimebase else { return }

        finishSwitch()
        try? controlTimebase?.removeTimer(switchTimer)
        timeJumpObserver.map(NotificationCenter.default.removeObserver)
        controlTimebase = timebase
        try? timebase?.addTimer(switchTimer)
        timeJumpObserver = timebase.map { timebase in
            NotificationCenter.default.addObserver(forName: CMTimebase.timeJumped, object: timebase, queue: nil) { [weak self, queue] _ in
                queue.justDispatch { [weak self] in self?.scheduleSwitch() }
            }
        }
        allLayers.forEach { $0.renderer.setControlTimebase(timebase) }
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        mediaDataRequest = (queue, block)
        leadRenderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        mediaDataRequest = nil
        allLayers.forEach { $0.renderer.stopRequestingMediaData() }
    }

    /// Keeps the samples from the last keyframe already on screen, so a layer added later can be
    /// brought up to date.
    private func trimHistory(of set: LayerSet) {
        let now = controlTimebase?.time ?? .positiveInfinity
        guard let start = set.history.lastIndex(where: { $0.isKeyframe && $0.outputPresentationTimeStamp <= now }) else {
            return
        }
        set.history.removeFirst(start)
    }

    private func restartMediaDataRequest() {
        guard let mediaDataRequest else { return }
        allLayers.forEach { $0.renderer.stopRequestingMediaData() }
        leadRenderer.requestMediaDataWhenReady(on: mediaDataRequest.queue, using: mediaDataRequest.block)
    }

    // MARK: - Switching sets

    /// Starts a new set for a video with another aspect ratio, shown from `time` on.
    private func startSwitch(presentationSize: CGSize, at time: CMTime) {
        // A switch still waiting for its time finishes right away.
        finishSwitch()

        let outputs = current.layers.compactMap(\.output)
        let layers = outputs.isEmpty
            ? [makeDisplayLayer()]
            : outputs.map { output in
                let displayLayer = makeDisplayLayer()
                displayLayer.output = output
                return displayLayer
            }

        previous = current
        current = LayerSet(layers: layers)
        current.presentationSize = presentationSize
        restartMediaDataRequest()

        switchTime = time
        scheduleSwitch()
    }

    /// Finishes the pending switch at its time. Runs again whenever the control timebase jumps: a
    /// timebase timer never fires for a time that is already behind, whether it was set that way
    /// (after a seek the new video can start at a keyframe before the current time) or the time
    /// jumped over it (as when the clock changes its source at an item boundary).
    private func scheduleSwitch() {
        guard previous != nil, let switchTime else { return }

        if let controlTimebase, switchTime >= controlTimebase.time {
            // Cleared first: setting the same time again does not reschedule the timer.
            try? controlTimebase.setTimerNextFireTime(switchTimer, fireTime: .invalid)
            try? controlTimebase.setTimerNextFireTime(switchTimer, fireTime: switchTime)
        } else {
            finishSwitch()
        }
    }

    /// Replaces the previous set with the current one on every output, in one step.
    private func finishSwitch() {
        guard let previous else { return }
        self.previous = nil
        switchTime = nil
        try? controlTimebase?.setTimerNextFireTime(switchTimer, fireTime: .invalid)
        previous.layers.forEach { $0.renderer.stopRequestingMediaData() }

        let newLayers = current.layers.compactMap { displayLayer in
            displayLayer.output.map { (layer: displayLayer.layer, output: $0) }
        }
        let oldLayers = previous.layers.compactMap { displayLayer in
            displayLayer.output.map { (layer: displayLayer.layer, output: $0) }
        }
        let presentationSize = current.presentationSize

        // The new size goes with the new layers, so a video rect changes together with the picture.
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            newLayers.forEach { $0.output.attach($0.layer) }
            oldLayers.forEach { $0.output.detach($0.layer) }
            if let presentationSize {
                newLayers.forEach { $0.output.setPresentationSize(presentationSize) }
            }
            CATransaction.commit()
        }
    }

    // MARK: - Making layers

    private func makeDisplayLayer() -> DisplayLayer {
        defer { makeSpareLayersIfNeeded() }
        // Without a spare, a layer made here is still better than none.
        let layer = spareLayers.popLast() ?? AVSampleBufferDisplayLayer()
        return DisplayLayer(layer: layer, controlTimebase: controlTimebase, delegate: delegate)
    }

    /// Keeps a spare layer for every output, so a switch finds all the layers it needs.
    private func makeSpareLayersIfNeeded() {
        guard !isMakingSpareLayer, spareLayers.count < max(1, current.layers.count) else { return }
        isMakingSpareLayer = true

        DispatchQueue.main.async { [weak self, queue] in
            // Handed to the player queue, which is the only one to use it from then on.
            nonisolated(unsafe) let layer = AVSampleBufferDisplayLayer()
            queue.justDispatch { [weak self] in
                guard let self else { return }
                self.spareLayers.append(layer)
                self.isMakingSpareLayer = false
                self.makeSpareLayersIfNeeded()
            }
        }
    }

    // MARK: - Layer tree

    private func show(_ layer: AVSampleBufferDisplayLayer, in output: VideoOutput, presentationSize: CGSize?) {
        DispatchQueue.main.async {
            output.attach(layer)
            if let presentationSize {
                output.setPresentationSize(presentationSize)
            }
        }
    }

    private func announcePresentationSize(_ size: CGSize, to outputs: [VideoOutput]) {
        DispatchQueue.main.async {
            outputs.forEach { $0.setPresentationSize(size) }
        }
    }

    private func hide(_ layer: AVSampleBufferDisplayLayer, from output: VideoOutput) {
        DispatchQueue.main.async {
            output.detach(layer)
        }
    }
}

/// The layers showing one video, one per output.
private final class LayerSet {
    var layers: [DisplayLayer]
    /// Presentation size of the video, known from the first sample.
    var presentationSize: CGSize?
    var aspectRatio: CGFloat? { presentationSize?.aspectRatio }
    /// Samples since the last keyframe already on screen.
    var history: [CMSampleBuffer] = []
    /// Time of the first sample since the set started or was flushed, shown or decoded only.
    var firstSampleTime: CMTime?

    init(layers: [DisplayLayer]) {
        self.layers = layers
    }
}

private final class DisplayLayer {
    let layer: AVSampleBufferDisplayLayer
    let renderer: VideoSampleBufferRenderer
    /// The output showing this layer; `nil` while the layer runs off-screen.
    weak var output: VideoOutput?

    init(layer: AVSampleBufferDisplayLayer, controlTimebase: CMTimebase?, delegate: VideoSampleBufferRendererDelegate?) {
        self.layer = layer
        if #available(macOS 14.4, iOS 17.4, tvOS 17.4, visionOS 1.1, *) {
            renderer = AVSBVideoRenderer(renderer: layer.sampleBufferRenderer, layer: layer)
        } else {
            renderer = AVSBDLVideoRenderer(layer: layer)
        }

        renderer.delegate = delegate
        renderer.setControlTimebase(controlTimebase)
    }
}

private extension CMSampleBuffer {
    /// Keyframes and decoded frames show without the samples before them.
    var isKeyframe: Bool {
        numSamples > 0 && (imageBuffer != nil || flags.contains(.keyframe))
    }

    var presentationSize: CGSize? {
        guard let formatDescription, formatDescription.mediaType == .video else { return nil }
        let size = formatDescription.presentationDimensions(usePixelAspectRatio: true, useCleanAperture: true)
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }
}

private extension CGSize {
    var aspectRatio: CGFloat { width / height }
}
