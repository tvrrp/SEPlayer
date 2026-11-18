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
/// An `AVSampleBufferDisplayLayer` reshapes its picture to the size of the last sample enqueued, not of the frame
/// on screen, so the frames still to show of the old size would be stretched. The outputs show the layers with the
/// `.resize` gravity and place them themselves; the size is passed on to them when the first frame of that size is
/// due, by a timer on the timebase.
///
/// Every layer follows the same ``RendererTimeSource``: it joins the synchronizer, or follows the
/// timebase. A layer that is let go leaves the synchronizer, which would keep waiting for it.
///
/// A layer keeps the clock it had when it got its first sample: its video queue rejects any other
/// control timebase from then on, and playback stalls. So a new clock, or the same one after the
/// layers left it, starts a new set. Its layers get the samples off-screen, while the old set keeps
/// its clock and its picture, and they replace the old ones once they show a frame.
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

    /// Whether a layer failed, or waits for a flush to decode again.
    var needsFlush: Bool {
        allLayers.contains { $0.renderer.hasFailed || $0.renderer.requiresFlushToResumeDecoding }
    }

    /// Whether the layers can show a frame. Also true while the video is still ahead of the current
    /// time, as at a paused item boundary: nothing is due yet, and waiting for a frame would keep
    /// playback from starting. After a seek the decoder starts from a keyframe at or before the
    /// seek position, so there the frame at the position is waited for.
    var isReadyForDisplay: Bool {
        if leadRenderer.isReadyForDisplay { return true }
        guard let firstSampleTime = current.firstSampleTime, let controlTimebase else {
            return false
        }
        return firstSampleTime > controlTimebase.time
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        leadRenderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    private let queue: any Queue
    private let switchTimer: DispatchSourceTimer
    /// When the pending switch shows the new set.
    private var switchTime: CMTime?
    /// Whether the pending switch shows the new set once it shows a frame: a switch of clock, where the old set
    /// keeps a clock the new one doesn't follow.
    private var switchesWhenShown = false
    private var timeJumpObserver: NSObjectProtocol?
    /// Fires when the next change of size is due.
    private let sizeTimer: DispatchSourceTimer
    /// The size the outputs show the picture at: the size of the frame on screen.
    private var displayedPresentationSize: CGSize?
    /// The size of the last frame enqueued.
    private var enqueuedPresentationSize: CGSize?
    /// Changes of size enqueued and not yet on screen, in the order they were enqueued.
    private var pendingSizeChanges: [(time: CMTime, size: CGSize)] = []
    /// The next change of size as the outputs were told of it: the size and the host time its first frame shows,
    /// infinite while the clock stands.
    private var announcedSizeChange: (size: CGSize, hostTime: CFTimeInterval)?
    private var rateObserver: NSObjectProtocol?

    /// The set that gets the samples.
    private var current: LayerSet
    /// The set still on screen until `current` reaches its first sample.
    private var previous: LayerSet?
    private var timeSource: RendererTimeSource?
    /// The time the layers play at.
    private var controlTimebase: CMTimebase? { timeSource?.timebase }
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
        current = LayerSet(layers: [DisplayLayer(layer: AVSampleBufferDisplayLayer(), timeSource: nil, delegate: nil)])
        switchTimer = DispatchSource.makeTimerSource(queue: queue.queue)
        sizeTimer = DispatchSource.makeTimerSource(queue: queue.queue)
        switchTimer.setEventHandler { [weak self] in
            self?.finishSwitch()
        }
        switchTimer.activate()
        sizeTimer.setEventHandler { [weak self] in
            self?.showDuePresentationSizes(timerFired: true)
        }
        sizeTimer.activate()
        queue.justDispatch { [weak self] in self?.makeSpareLayersIfNeeded() }
    }

    deinit {
        timeJumpObserver.map(NotificationCenter.default.removeObserver)
        rateObserver.map(NotificationCenter.default.removeObserver)
        switchTimer.cancel()
        sizeTimer.cancel()
    }

    // MARK: - Outputs

    func addOutput(_ output: VideoOutput) {
        assert(queue.isCurrent())
        guard !current.layers.contains(where: { $0.output === output }) else {
            return
        }

        // While a switch is pending, the output needs a layer in both sets.
        if let previous {
            add(output, to: previous)
        }
        add(output, to: current)
    }

    func removeOutput(_ output: VideoOutput) {
        assert(queue.isCurrent())

        for set in [current, previous].compactMap({ $0 }) {
            guard let displayLayer = set.layers.first(where: { $0.output === output }) else {
                continue
            }

            displayLayer.output = nil
            hide(displayLayer.layer, from: output)

            // The last layer of a set stays, off-screen, so the renderer keeps running.
            if set.layers.count > 1 {
                displayLayer.renderer.stopRequestingMediaData()
                displayLayer.follow(nil)
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
            set.history.forEach { displayLayer.enqueue($0.buffer) }
            set.layers.append(displayLayer)
        }
        displayLayer.output = output

        // The layers of a pending switch go on screen when it finishes.
        if set !== current || previous == nil {
            show(displayLayer.layer, in: output, sizes: presentationSizesForNewOutput)
        }
    }

    // MARK: - Samples

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // The timer of a change can be lost when the clock changes its source; the samples keep coming meanwhile.
        if let next = pendingSizeChanges.first, let now = controlTimebase?.time, next.time <= now {
            showDuePresentationSizes()
        }
        if sampleBuffer.numSamples > 0, let presentationSize = sampleBuffer.presentationSize {
            scheduleSizeChange(to: presentationSize, at: sampleBuffer.outputPresentationTimeStamp)
        }

        if current.firstSampleTime == nil, sampleBuffer.numSamples > 0 {
            current.firstSampleTime = sampleBuffer.outputPresentationTimeStamp
            switchAtFirstSampleIfReadinessUnknown()
        }

        current.layers.forEach { $0.enqueue(sampleBuffer) }
        current.history.append(HistorySample(sampleBuffer))
        trimHistory(of: current)
    }

    func flush(removeImage: Bool = false) {
        assert(queue.isCurrent())
        // The old set of a switch of clock keeps its picture until the new set has one.
        if removeImage || !switchesWhenShown {
            finishSwitch()
        }
        current.layers.forEach { $0.flush(removeImage: removeImage) }
        current.history.removeAll()
        current.firstSampleTime = nil
        // The frames of the changes still to come are gone; outputs holding one for its time go back.
        if !pendingSizeChanges.isEmpty {
            SELogger.debug(.display, "display layers: flush drops \(pendingSizeChanges.count) size changes")
        }
        pendingSizeChanges.removeAll()
        enqueuedPresentationSize = displayedPresentationSize
        try? controlTimebase?.setTimerNextFireTime(sizeTimer, fireTime: .invalid)
        if announcedSizeChange != nil {
            announcedSizeChange = nil
            if let displayedPresentationSize {
                announcePresentationSize(displayedPresentationSize, at: nil)
            }
        }
    }

    /// Promises the layers that no sample enqueued from now on has a time below `time`, so the display can skip
    /// looking for new frames until then. Forward playback only; a flush ends the promise.
    func expectMinimumUpcomingPresentationTime(_ time: CMTime) {
        assert(queue.isCurrent())
        guard (controlTimebase?.rate ?? 0) >= 0 else { return }
        // Layers of a pending switch get the samples, so they get the promise too; the old ones get neither.
        current.layers.forEach { $0.expectMinimumUpcomingPresentationTime(time) }
    }

    /// Withdraws the promise, for samples that may go back in time without a flush.
    func resetPresentationTimeExpectation() {
        assert(queue.isCurrent())
        current.layers.forEach { $0.resetPresentationTimeExpectation() }
    }

    func setTimeSource(_ source: RendererTimeSource?) {
        assert(queue.isCurrent())
        guard source.map({ !$0.isIdentical(to: timeSource) }) ?? (timeSource != nil) else {
            return
        }

        SELogger.debug(.display, "display layers: time source -> \(source.map { $0.synchronizer != nil ? "synchronizer" : "timebase" } ?? "none")")
        finishSwitch()
        let timebase = source?.timebase
        if timebase !== controlTimebase {
            try? controlTimebase?.removeTimer(switchTimer)
            try? controlTimebase?.removeTimer(sizeTimer)
            timeJumpObserver.map(NotificationCenter.default.removeObserver)
            rateObserver.map(NotificationCenter.default.removeObserver)
            try? timebase?.addTimer(switchTimer)
            try? timebase?.addTimer(sizeTimer)
            timeJumpObserver = timebase.map { timebase in
                NotificationCenter.default.addObserver(forName: CMTimebase.timeJumped, object: timebase, queue: nil) { [weak self, queue] _ in
                    queue.justDispatch { [weak self] in
                        self?.scheduleSwitch()
                        self?.showDuePresentationSizes()
                    }
                }
            }
            // The host time of the next change moves with the rate.
            rateObserver = timebase.map { timebase in
                NotificationCenter.default.addObserver(forName: CMTimebase.effectiveRateChanged, object: timebase, queue: nil) { [weak self, queue] _ in
                    let rateDidChange = { [weak self] in
                        guard let self else { return }
                        SELogger.debug(.display, "display layers: rate \(timebase.rate), video−clock "
                            + current.layers.map { self.describeOffset(of: $0) }.joined(separator: ", "))
                        showDuePresentationSizes()
                    }
                    // A renderer that stops the clock on this queue, just before a change of size, would otherwise
                    // keep the queue until the outputs had already applied the change at its old time.
                    if queue.isCurrent() { rateDidChange() } else { queue.justDispatch(rateDidChange) }
                }
            }
        }
        timeSource = source
        defer { showDuePresentationSizes() }
        if let source, current.layers.contains(where: { !$0.canFollow(source) }) {
            startClockSwitch()
        } else {
            current.layers.forEach { $0.follow(source) }
        }
    }

    /// Finishes a switch of clock once the new set shows a frame.
    func readyForDisplayDidChange() {
        assert(queue.isCurrent())
        guard switchesWhenShown, leadRenderer.isReadyForDisplay else { return }
        finishSwitch()
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
        guard let start = set.history.lastIndex(where: { $0.isKeyframe && $0.presentationTime <= now }) else {
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

    /// Starts a new set on the current clock, with the samples the old set still has to show. The old set keeps its
    /// clock and its picture until the new one shows a frame.
    private func startClockSwitch() {
        let old = current
        previous = old
        current = LayerSet(layers: makeLayersForOutputs(of: old))
        current.history = old.history
        current.firstSampleTime = old.history.first { $0.buffer.numSamples > 0 }?.presentationTime
        old.history.forEach { sample in current.layers.forEach { $0.enqueue(sample.buffer) } }
        restartMediaDataRequest()

        switchTime = nil
        switchesWhenShown = true
        SELogger.debug(.display, "display layers: new layers for the new clock, \(old.history.count) samples carried over")
        switchAtFirstSampleIfReadinessUnknown()
    }

    /// Without readiness for display to tell, a switch of clock shows the new set at the time of its first sample.
    private func switchAtFirstSampleIfReadinessUnknown() {
        guard switchesWhenShown, let firstSampleTime = current.firstSampleTime else {
            return
        }
        if #unavailable(macOS 14.4, iOS 17.4, tvOS 17.4, visionOS 1.1) {
            switchesWhenShown = false
            switchTime = firstSampleTime
            scheduleSwitch()
        }
    }

    /// A new layer for every output of `set`, or one off-screen layer when it has none.
    private func makeLayersForOutputs(of set: LayerSet) -> [DisplayLayer] {
        let outputs = set.layers.compactMap(\.output)
        guard !outputs.isEmpty else { return [makeDisplayLayer()] }
        return outputs.map { output in
            let displayLayer = makeDisplayLayer()
            displayLayer.output = output
            return displayLayer
        }
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
        switchesWhenShown = false
        try? controlTimebase?.setTimerNextFireTime(switchTimer, fireTime: .invalid)
        previous.layers.forEach { $0.renderer.stopRequestingMediaData() }

        let newLayers = current.layers.compactMap { displayLayer in
            displayLayer.output.map { (layer: displayLayer.layer, output: $0) }
        }
        let oldLayers = previous.layers.compactMap { displayLayer in
            displayLayer.output.map { (layer: displayLayer.layer, output: $0) }
        }
        let sizes = presentationSizesForNewOutput
        let oldRenderers = previous.layers.map(\.renderer)

        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            newLayers.forEach { $0.output.attach($0.layer) }
            oldLayers.forEach { $0.output.detach($0.layer) }
            for size in sizes {
                newLayers.forEach { $0.output.setPresentationSize(size.size, at: size.hostTime) }
            }
            CATransaction.commit()
            // Off screen now, the old layers leave the synchronizer.
            oldRenderers.forEach { $0.setTimeSource(nil) }
        }
    }

    /// How far the layer's own clock is from the time source's, in milliseconds, with its rate: for debugging.
    private func describeOffset(of displayLayer: DisplayLayer) -> String {
        guard let controlTimebase, let layerTimebase = displayLayer.layer.timebase as CMTimebase? else {
            return "—"
        }
        let offset = (layerTimebase.time - controlTimebase.time).seconds * 1000
        return String(format: "%+.1f ms × %g", offset, layerTimebase.rate)
    }

    // MARK: - Size

    /// Tells the outputs of a new size and when its first frame shows: a display layer resizes its picture as soon as
    /// such a frame is enqueued, and the outputs place the layer. They apply it at that host time, the render server
    /// doing it together with the frame; the timer then confirms it.
    private func scheduleSizeChange(to size: CGSize, at time: CMTime) {
        if size != enqueuedPresentationSize {
            SELogger.debug(.display, "display layers: size \(size) enqueued for \(time.seconds), clock \(controlTimebase?.time.seconds ?? .nan)")
            enqueuedPresentationSize = size
            pendingSizeChanges.append((time, size))
        } else if let last = pendingSizeChanges.indices.last, time < pendingSizeChanges[last].time {
            // Frames in decode order: a frame after the first with the new size can show before it.
            pendingSizeChanges[last].time = time
        } else {
            return
        }
        showDuePresentationSizes()
    }

    /// Shows the sizes whose frames are due, and sets the timer for the next one. The first size shows at once: there
    /// is no picture yet to keep, and the outputs need it to place the layers.
    ///
    /// - Parameter timerFired: Whether the timer of the next change fired. That change is due even if the clock reads
    ///   a little before its time: set again for a time already behind, the timer would never fire.
    private func showDuePresentationSizes(timerFired: Bool = false) {
        let now = controlTimebase?.time
        var due: CGSize?
        var isFirstDue = timerFired || displayedPresentationSize == nil
        while let change = pendingSizeChanges.first, isFirstDue || now.map({ change.time <= $0 }) ?? true {
            isFirstDue = false
            due = change.size
            pendingSizeChanges.removeFirst()
        }
        if let due, due != displayedPresentationSize {
            SELogger.debug(.display, "display layers: size \(due) shown at clock \(now?.seconds ?? .nan)\(timerFired ? " (timer)" : "")")
            displayedPresentationSize = due
            announcedSizeChange = nil
            announcePresentationSize(due, at: nil)
        }
        announceNextSizeChange()

        guard let controlTimebase else { return }
        // Cleared first: setting the same time again does not reschedule the timer.
        try? controlTimebase.setTimerNextFireTime(sizeTimer, fireTime: .invalid)
        if let next = pendingSizeChanges.first {
            do {
                try controlTimebase.setTimerNextFireTime(sizeTimer, fireTime: next.time)
            } catch {
                SELogger.debug(.display, "display layers: size timer for \(next.time.seconds) not set: \(error)")
            }
        }
    }

    /// Tells the outputs when the next change of size shows, in host time, when that time moved.
    private func announceNextSizeChange() {
        guard let next = pendingSizeChanges.first, let controlTimebase else {
            return
        }
        // A standing clock gives no time yet; the outputs keep the size on screen until it moves.
        let hostTime = controlTimebase.rate > 0
            ? controlTimebase.convertTime(next.time, to: CMClock.hostTimeClock).seconds
            : .infinity
        if let announced = announcedSizeChange, announced.size == next.size,
           announced.hostTime == hostTime || abs(announced.hostTime - hostTime) < 0.001 {
            return
        }
        SELogger.debug(.display, "display layers: size \(next.size) due at host \(hostTime), now \(CACurrentMediaTime())")
        announcedSizeChange = (next.size, hostTime)
        announcePresentationSize(next.size, at: hostTime)
    }

    /// What a new output needs: the size on screen, then the change of size it waits for.
    private var presentationSizesForNewOutput: [(size: CGSize, hostTime: CFTimeInterval?)] {
        var sizes: [(size: CGSize, hostTime: CFTimeInterval?)] = []
        if let displayedPresentationSize { sizes.append((displayedPresentationSize, nil)) }
        if let announcedSizeChange { sizes.append((announcedSizeChange.size, announcedSizeChange.hostTime)) }
        return sizes
    }

    // MARK: - Making layers

    private func makeDisplayLayer() -> DisplayLayer {
        defer { makeSpareLayersIfNeeded() }
        // Without a spare, a layer made here is still better than none.
        let layer = spareLayers.popLast() ?? AVSampleBufferDisplayLayer()
        return DisplayLayer(layer: layer, timeSource: timeSource, delegate: delegate)
    }

    /// Keeps a spare layer for every output, so a switch finds all the layers it needs.
    private func makeSpareLayersIfNeeded() {
        guard !isMakingSpareLayer, spareLayers.count < max(1, current.layers.count) else {
            return
        }
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

    private func show(
        _ layer: AVSampleBufferDisplayLayer,
        in output: VideoOutput,
        sizes: [(size: CGSize, hostTime: CFTimeInterval?)]
    ) {
        DispatchQueue.main.async {
            output.attach(layer)
            sizes.forEach { output.setPresentationSize($0.size, at: $0.hostTime) }
        }
    }

    private func announcePresentationSize(_ size: CGSize, at hostTime: CFTimeInterval?) {
        var outputs: [VideoOutput] = []
        for output in allLayers.compactMap(\.output) where !outputs.contains(where: { $0 === output }) {
            outputs.append(output)
        }
        DispatchQueue.main.async {
            outputs.forEach { $0.setPresentationSize(size, at: hostTime) }
        }
    }

    private func hide(_ layer: AVSampleBufferDisplayLayer, from output: VideoOutput) {
        DispatchQueue.main.async {
            output.detach(layer)
        }
    }
}

/// A sample kept to bring a new layer up to date, with what trimming the history reads of it.
private struct HistorySample {
    let buffer: CMSampleBuffer
    /// Whether the sample shows without the ones before it.
    let isKeyframe: Bool
    let presentationTime: CMTime

    /// Reads the attachments once: the history is searched on every sample enqueued.
    init(_ buffer: CMSampleBuffer) {
        self.buffer = buffer
        isKeyframe = buffer.isKeyframe
        presentationTime = buffer.outputPresentationTimeStamp
    }
}

/// The layers showing one video, one per output.
private final class LayerSet {
    var layers: [DisplayLayer]
    /// Samples since the last keyframe already on screen.
    var history: [HistorySample] = []
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
    /// The clock the layer follows.
    private var timeSource: RendererTimeSource?
    /// Whether the layer got a sample: its clock can't change from then on.
    private var hasSamples = false
    /// The lowest time promised for the samples to come; `nil` while nothing is promised.
    private var promisedMinimumTime: CMTime?

    init(layer: AVSampleBufferDisplayLayer, timeSource: RendererTimeSource?, delegate: VideoSampleBufferRendererDelegate?) {
        self.layer = layer
        if #available(macOS 14.4, iOS 17.4, tvOS 17.4, visionOS 1.1, *) {
            renderer = AVSBVideoRenderer(renderer: layer.sampleBufferRenderer, layer: layer)
        } else {
            renderer = AVSBDLVideoRenderer(layer: layer)
        }

        renderer.delegate = delegate
        follow(timeSource)
    }

    /// Whether the layer can play to `source`: before its first sample, any clock; after it, only the one it has.
    func canFollow(_ source: RendererTimeSource) -> Bool {
        !hasSamples || source.isIdentical(to: timeSource)
    }

    func follow(_ source: RendererTimeSource?) {
        timeSource = source
        renderer.setTimeSource(source)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        hasSamples = true
        renderer.enqueue(sampleBuffer)
    }

    func flush(removeImage: Bool) {
        renderer.flush(removeImage: removeImage)
        // The flush ended the promise.
        promisedMinimumTime = nil
    }

    /// Promises a lower bound only once it moved on by `minimumPromiseStep`: every new bound is a synchronous call
    /// into the video queue, and a bound that lags a little only shortens the time the display skips.
    func expectMinimumUpcomingPresentationTime(_ time: CMTime) {
        guard time.isNumeric else { return }
        if let promisedMinimumTime, time - promisedMinimumTime < Self.minimumPromiseStep { return }
        promisedMinimumTime = time
        renderer.setPresentationTimeExpectation(.minimumUpcoming(time))
    }

    func resetPresentationTimeExpectation() {
        guard promisedMinimumTime != nil else { return }
        promisedMinimumTime = nil
        renderer.setPresentationTimeExpectation(.none)
    }

    private static let minimumPromiseStep = CMTime(value: 1, timescale: 4)
}

private extension CMSampleBuffer {
    /// Keyframes and decoded frames show without the samples before them.
    var isKeyframe: Bool {
        numSamples > 0 && (imageBuffer != nil || flags.contains(.keyframe))
    }

    var presentationSize: CGSize? {
        guard let formatDescription, formatDescription.mediaType == .video else {
            return nil
        }
        let size = formatDescription.presentationDimensions(usePixelAspectRatio: true, useCleanAperture: true)
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }
}
