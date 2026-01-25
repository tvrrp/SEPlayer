//
//  RenderersHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.05.2025.
//

import CoreMedia

final class RenderersHolder {
    let primaryRenderer: SERenderer
    private let index: Int
    let secondaryRenderer: SERenderer?

    private var prewarmingState: RendererPrewarmingState
    private var primaryRequiresReset: Bool
    private var secondaryRequiresReset: Bool
    
    init(primaryRenderer: SERenderer, secondaryRenderer: SERenderer? = nil, index: Int) {
        self.primaryRenderer = primaryRenderer
        self.secondaryRenderer = secondaryRenderer
        self.index = index
        self.prewarmingState = .notPrewarmingUsingPrimary
        self.primaryRequiresReset = false
        self.secondaryRequiresReset = false
    }

    func startPrewarming() {
        guard !isPrewarming else { return }
        
        prewarmingState = if isRendererEnabled(renderer: primaryRenderer) {
            .transitioningToSecondary
        } else {
            if let secondaryRenderer, isRendererEnabled(renderer: secondaryRenderer) {
                .transitioningToPrimary
            } else {
                .prewarmingPrimary
            }
        }
    }
    
    func isRendererPrewarming(id: Int) -> Bool {
        let isPrewarmingPrimaryRenderer = isPrimaryRendererPrewarming && id == index
        let isPrewarmingSecondaryRenderer = isSecondaryRendererPrewarming && id == index
        return isPrewarmingPrimaryRenderer || isPrewarmingSecondaryRenderer
    }
    
    func readingPositionUs(for holder: MediaPeriodHolder?) -> Int64 {
        rendererReading(from: holder)?.getReadingPosition() ?? .timeUnset
    }
    
    func didReadStreamToEnd(for holder: MediaPeriodHolder) -> Bool {
        rendererReading(from: holder)?.didReadStreamToEnd() ?? true
    }
    
    func setCurrentStreamFinal(for holder: MediaPeriodHolder, streamEndPositionUs: Int64) {
        guard let renderer = rendererReading(from: holder) else {
            assertionFailure()
            return
        }
        
        setCurrentStreamFinalInternal(renderer: renderer, streamEndPositionUs: streamEndPositionUs)
    }
    
    func maybeSetOldStreamToFinal(
        oldTrackSelectorResult: TrackSelectionResult,
        newTrackSelectorResult: TrackSelectionResult,
        streamEndPositionUs: Int64
    ) {
        let oldRendererEnabled = oldTrackSelectorResult.isRendererEnabled(for: index)
        let newRendererEnabled = newTrackSelectorResult.isRendererEnabled(for: index)
        let isPrimaryOldRenderer = secondaryRenderer == nil
        || prewarmingState == .transitioningToSecondary
        || ( prewarmingState == .notPrewarmingUsingPrimary && isRendererEnabled(renderer: primaryRenderer))
        
        let oldRenderer = isPrimaryOldRenderer ? primaryRenderer : secondaryRenderer
        guard let oldRenderer else { return }
        
        if oldRendererEnabled, !oldRenderer.isCurrentStreamFinal() {
            let isNoSampleRenderer = trackType == .none
            let oldConfig = oldTrackSelectorResult.renderersConfig[index]
            let newConfig = newTrackSelectorResult.renderersConfig[index]
            
            if !newRendererEnabled || oldConfig != newConfig || isNoSampleRenderer || isPrewarming {
                setCurrentStreamFinalInternal(renderer: oldRenderer, streamEndPositionUs: streamEndPositionUs)
            }
        }
    }
    
    func setAllNonPrewarmingRendererStreamsFinal(streamEndPositionUs: Int64) {
        if isRendererEnabled(renderer: primaryRenderer),
           prewarmingState != .transitioningToPrimary,
           prewarmingState != .prewarmingPrimary {
            setCurrentStreamFinalInternal(renderer: primaryRenderer, streamEndPositionUs: streamEndPositionUs)
        }
        
        if let secondaryRenderer, isRendererEnabled(renderer: secondaryRenderer),
           prewarmingState != .transitioningToSecondary {
            setCurrentStreamFinalInternal(renderer: secondaryRenderer, streamEndPositionUs: streamEndPositionUs)
        }
    }
    
    func enableMayRenderStartOfStream() {
        if isRendererEnabled(renderer: primaryRenderer) {
            primaryRenderer.enableRenderStartOfStream()
        } else if let secondaryRenderer, isRendererEnabled(renderer: secondaryRenderer) {
            secondaryRenderer.enableRenderStartOfStream()
        }
    }
    
    func setPlaybackSpeed(current: Float, target: Float) throws {
        try! primaryRenderer.setPlaybackSpeed(current: current, target: target)
        try! secondaryRenderer?.setPlaybackSpeed(current: current, target: target)
    }
    
    func setTimeline(_ timeline: Timeline) {
        primaryRenderer.setTimeline(timeline)
        secondaryRenderer?.setTimeline(timeline)
    }
    
    func isReading(from period: MediaPeriodHolder) -> Bool {
        return rendererReading(from: period) != nil
    }
    
    func isPrewarming(period: MediaPeriodHolder) -> Bool {
        let isPrimaryRendererPrewarming = isPrimaryRendererPrewarming && rendererReading(from: period) === primaryRenderer
        let isSecondaryRendererPrewarming = isSecondaryRendererPrewarming && rendererReading(from: period) === secondaryRenderer

        return isPrimaryRendererPrewarming || isSecondaryRendererPrewarming
    }

    func hasFinishedReading(from period: MediaPeriodHolder) -> Bool {
        hasFinishedReading(from: period, renderer: primaryRenderer)
            && hasFinishedReading(from: period, renderer: secondaryRenderer)
    }

    func render(rendererPositionUs: Int64, rendererPositionElapsedRealtimeUs: Int64) throws {
        if isRendererEnabled(renderer: primaryRenderer) {
            try primaryRenderer.render(
                position: rendererPositionUs,
                elapsedRealtime: rendererPositionElapsedRealtimeUs
            )
        }
        if let secondaryRenderer, isRendererEnabled(renderer: secondaryRenderer) {
            try secondaryRenderer.render(
                position: rendererPositionUs,
                elapsedRealtime: rendererPositionElapsedRealtimeUs
            )
        }
    }

    func allowsPlayback(playingPeriodHolder: MediaPeriodHolder) -> Bool {
        guard let renderer = rendererReading(from: playingPeriodHolder) else {
            return true
        }

        return renderer.didReadStreamToEnd() || renderer.isReady() || renderer.isEnded()
    }

    func start() throws {
        if primaryRenderer.getState() == .enabled, prewarmingState != .transitioningToPrimary {
            try! primaryRenderer.start()
        } else if let secondaryRenderer,
                  secondaryRenderer.getState() == .enabled,
                  prewarmingState != .transitioningToSecondary {
            try! secondaryRenderer.start()
        }
    }

    func stop() {
        if isRendererEnabled(renderer: primaryRenderer) {
            ensureStopped(renderer: primaryRenderer)
        }
        if let secondaryRenderer, isRendererEnabled(renderer: secondaryRenderer) {
            ensureStopped(renderer: secondaryRenderer)
        }
    }

    func enable(
        trackSelection: SETrackSelection,
        stream: SampleStream,
        positionUs: Int64,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPositionUs: Int64,
        offsetUs: Int64,
        mediaPeriodId: MediaPeriodId,
        mediaClock: DefaultMediaClock
    ) throws {
        let formats = formats(from: trackSelection)
        let enablePrimary = [.notPrewarmingUsingPrimary, .prewarmingPrimary, .transitioningToPrimary].contains(prewarmingState)

        if enablePrimary {
            primaryRequiresReset = true
            try! primaryRenderer.enable(
                formats: formats,
                stream: stream,
                position: positionUs,
                joining: joining,
                mayRenderStartOfStream: mayRenderStartOfStream,
                startPosition: startPositionUs,
                offset: offsetUs,
                mediaPeriodId: mediaPeriodId
            )
            mediaClock.onRendererEnabled(renderer: primaryRenderer)
        } else if let secondaryRenderer {
            secondaryRequiresReset = true
            try! secondaryRenderer.enable(
                formats: formats,
                stream: stream,
                position: positionUs,
                joining: joining,
                mayRenderStartOfStream: mayRenderStartOfStream,
                startPosition: startPositionUs,
                offset: offsetUs,
                mediaPeriodId: mediaPeriodId
            )
            mediaClock.onRendererEnabled(renderer: secondaryRenderer)
        }
    }

    func handleMessage(_ message: RendererMessage, mediaPeriod: MediaPeriodHolder) throws {
        try rendererReading(from: mediaPeriod)?.handleMessage(message)
    }

    func disable(mediaClock: DefaultMediaClock) throws {
        disableRenderer(renderer: primaryRenderer, mediaClock: mediaClock)
        if let secondaryRenderer {
            let shouldTransferResources = isRendererEnabled(renderer: secondaryRenderer) && prewarmingState == .transitioningToSecondary
            disableRenderer(renderer: secondaryRenderer, mediaClock: mediaClock)
            maybeResetRenderer(resetPrimary: false)
            if shouldTransferResources {
                try! transferResources(transferToPrimary: true)
            }
        }

        prewarmingState = .notPrewarmingUsingPrimary
    }

    func maybeHandlePrewarmingTransition() throws {
        if prewarmingState == .transitioningToSecondary || prewarmingState == .transitioningToPrimary {
            try! transferResources(transferToPrimary: prewarmingState == .transitioningToPrimary)
            prewarmingState = prewarmingState == .transitioningToPrimary ? .notPrewarmingUsingPrimary : .notPrewarmingUsingSecondary
        } else if prewarmingState == .prewarmingPrimary {
            prewarmingState = .notPrewarmingUsingPrimary
        }
    }

    func disablePrewarming(mediaClock: DefaultMediaClock) {
        guard isPrewarming else { return }

        let isPrewarmingPrimary = [.transitioningToPrimary, .prewarmingPrimary].contains(prewarmingState)
        let isSecondaryActiveRenderer = prewarmingState == .transitioningToPrimary
        if isPrewarmingPrimary {
            disableRenderer(renderer: primaryRenderer, mediaClock: mediaClock)
        } else if let secondaryRenderer {
            disableRenderer(renderer: secondaryRenderer, mediaClock: mediaClock)
        }
        maybeResetRenderer(resetPrimary: isPrewarmingPrimary)
        prewarmingState = isSecondaryActiveRenderer ? .notPrewarmingUsingSecondary : .notPrewarmingUsingPrimary
    }

    func maybeDisableOrResetPosition(
        sampleStream: SampleStream,
        mediaClock: DefaultMediaClock,
        rendererPositionUs: Int64,
        streamReset: Bool
    ) throws {
        try! maybeDisableOrResetPositionInternal(
            renderer: primaryRenderer,
            sampleStream: sampleStream,
            mediaClock: mediaClock,
            rendererPositionUs: rendererPositionUs,
            streamReset: streamReset
        )

        if let secondaryRenderer {
            try! maybeDisableOrResetPositionInternal(
                renderer: secondaryRenderer,
                sampleStream: sampleStream,
                mediaClock: mediaClock,
                rendererPositionUs: rendererPositionUs,
                streamReset: streamReset
            )
        }
    }

    func resetPosition(for holder: MediaPeriodHolder?, positionUs: Int64) throws {
        try! rendererReading(from: holder)?.resetPosition(new: positionUs)
    }

    func reset() {
        if !isRendererEnabled(renderer: primaryRenderer) {
            maybeResetRenderer(resetPrimary: true)
        }

        if let secondaryRenderer, !isRendererEnabled(renderer: secondaryRenderer) {
            maybeResetRenderer(resetPrimary: false)
        }
    }

    func replaceStreamsOrDisableRendererForTransition(
        readingPeriodHolder: MediaPeriodHolder,
        newTrackSelectorResult: TrackSelectionResult,
        mediaClock: DefaultMediaClock
    ) throws -> Bool {
        let primaryRendererResult = try! replaceStreamsOrDisableRendererForTransitionInternal(
            primaryRenderer,
            readingPeriodHolder: readingPeriodHolder,
            newTrackSelectorResult: newTrackSelectorResult,
            mediaClock: mediaClock
            
        )

        let secondaryRendererResult = try! replaceStreamsOrDisableRendererForTransitionInternal(
            secondaryRenderer,
            readingPeriodHolder: readingPeriodHolder,
            newTrackSelectorResult: newTrackSelectorResult,
            mediaClock: mediaClock
            
        )

        return primaryRendererResult ? secondaryRendererResult : primaryRendererResult
    }

    func release() {
        primaryRenderer.release()
        primaryRequiresReset = false
        secondaryRenderer?.release()
        secondaryRequiresReset = false
    }

    func setControlTimebase(_ timebase: TimebaseSource?) throws {
        guard let timebase else {
            try primaryRenderer.handleMessage(.setControlTimebase(timebase))
            try secondaryRenderer?.handleMessage(.setControlTimebase(timebase))
            return
        }

        if prewarmingState == .transitioningToPrimary || prewarmingState == .notPrewarmingUsingSecondary {
            try secondaryRenderer?.handleMessage(.setControlTimebase(timebase))
        } else {
            try primaryRenderer.handleMessage(.setControlTimebase(timebase))
        }
    }

    func setVideoOutput(_ output: VideoSampleBufferRenderer) throws {
        guard trackType == .video else { return }

        if prewarmingState == .transitioningToPrimary || prewarmingState == .notPrewarmingUsingSecondary {
            try secondaryRenderer?.handleMessage(.setVideoOutput(output))
        } else {
            try primaryRenderer.handleMessage(.setVideoOutput(output))
        }
    }

    func removeVideoOutput(_ output: VideoSampleBufferRenderer) throws {
        guard trackType == .video else { return }
        try secondaryRenderer?.handleMessage(.removeVideoOutput(output))
        try primaryRenderer.handleMessage(.removeVideoOutput(output))
    }

    func setVolume(_ volume: Float) throws {
        guard trackType == .audio else { return }
        try primaryRenderer.handleMessage(.setAudioVolume(volume))
        try secondaryRenderer?.handleMessage(.setAudioVolume(volume))
    }

    func setAudioIsMuted(_ isMuted: Bool) throws {
        guard trackType == .audio else { return }
        try primaryRenderer.handleMessage(.setAudioIsMuted(isMuted))
        try secondaryRenderer?.handleMessage(.setAudioIsMuted(isMuted))
    }
}

extension RenderersHolder {
    var hasSecondary: Bool {
        secondaryRenderer != nil
    }

    var isPrewarming: Bool {
        isPrimaryRendererPrewarming || isSecondaryRendererPrewarming
    }

    var enabledRendererCount: Int {
        var result = isRendererEnabled(renderer: primaryRenderer) ? 1 : 0
        if let secondaryRenderer {
            result += isRendererEnabled(renderer: secondaryRenderer) ? 1 : 0
        }
        return result
    }

    var trackType: TrackType { primaryRenderer.trackType }

    var isEnded: Bool {
        var renderersEnded = true
        if isRendererEnabled(renderer: primaryRenderer) {
            renderersEnded = renderersEnded && primaryRenderer.isEnded()
        }
        if let secondaryRenderer, isRendererEnabled(renderer: secondaryRenderer) {
            renderersEnded = renderersEnded && secondaryRenderer.isEnded()
        }

        return renderersEnded
    }

    var isRendererEnabled: Bool {
        let checkPrimary = [.notPrewarmingUsingPrimary, .prewarmingPrimary, .transitioningToPrimary]
            .contains(prewarmingState)

        if checkPrimary {
            return isRendererEnabled(renderer: primaryRenderer)
        } else if let secondaryRenderer {
            return isRendererEnabled(renderer: secondaryRenderer)
        } else {
            return false
        }
    }
}

private extension RenderersHolder {
    private var isPrimaryRendererPrewarming: Bool {
        prewarmingState == .prewarmingPrimary || prewarmingState == .transitioningToPrimary
    }

    private var isSecondaryRendererPrewarming: Bool {
        prewarmingState == .transitioningToSecondary
    }
}

private extension RenderersHolder {
    func setCurrentStreamFinalInternal(renderer: SERenderer, streamEndPositionUs: Int64) {
        renderer.setStreamFinal()
    }

    func hasFinishedReading(from readingPeriodHolder: MediaPeriodHolder, renderer: SERenderer?) -> Bool {
        guard let renderer else { return true }

        let sampleStream = readingPeriodHolder.sampleStreams[index]
        if (renderer.getStream() != nil && renderer.getStream() !== sampleStream) ||
            (sampleStream != nil && !renderer.didReadStreamToEnd()) {
            let followingPeriod = readingPeriodHolder.next

            return followingPeriod != nil && followingPeriod?.sampleStreams[index] === renderer.getStream()
        }

        return true
    }

    func ensureStopped(renderer: SERenderer) {
        if renderer.getState() == .started {
            renderer.stop()
        }
    }

    func transferResources(transferToPrimary: Bool) throws {
        if transferToPrimary {
            // TODO:
        } else {
            // TODO:
        }
    }

    func maybeDisableOrResetPositionInternal(
        renderer: SERenderer,
        sampleStream: SampleStream,
        mediaClock: DefaultMediaClock,
        rendererPositionUs: Int64,
        streamReset: Bool
    ) throws {
        guard isRendererEnabled(renderer: renderer) else { return }

        if sampleStream !== renderer.getStream() {
            disableRenderer(renderer: renderer, mediaClock: mediaClock)
        } else {
            try! renderer.resetPosition(new: rendererPositionUs)
        }
    }

    func disableRenderer(renderer: SERenderer, mediaClock: DefaultMediaClock) {
        guard primaryRenderer === renderer || secondaryRenderer === renderer else {
            assertionFailure()
            return
        }

        guard isRendererEnabled(renderer: renderer) else { return }
        try? renderer.handleMessage(.stopRequestingMediaData)
        mediaClock.onRendererDisabled(renderer: renderer)
        ensureStopped(renderer: renderer)
        renderer.disable()
    }

    func maybeResetRenderer(resetPrimary: Bool) {
        if resetPrimary {
            if primaryRequiresReset {
                primaryRenderer.reset()
                primaryRequiresReset = false
            }
        } else if secondaryRequiresReset {
            secondaryRenderer?.reset()
            secondaryRequiresReset = false
        }
    }

    func replaceStreamsOrDisableRendererForTransitionInternal(
        _ renderer: SERenderer?,
        readingPeriodHolder: MediaPeriodHolder,
        newTrackSelectorResult: TrackSelectionResult,
        mediaClock: DefaultMediaClock
    ) throws -> Bool {
        guard let renderer, isRendererEnabled(renderer: renderer),
            !(renderer === primaryRenderer && isPrimaryRendererPrewarming),
            !(renderer === secondaryRenderer && isSecondaryRendererPrewarming)
        else {
            return true
        }

        let rendererIsReadingOldStream = renderer.getStream() !== readingPeriodHolder.sampleStreams[index]
        let rendererShouldBeEnabled = newTrackSelectorResult.isRendererEnabled(for: index)

        if rendererShouldBeEnabled && !rendererIsReadingOldStream {
            return true
        }

        if !renderer.isCurrentStreamFinal(), let sampleStream = readingPeriodHolder.sampleStreams[index] {
            let formats = formats(from: newTrackSelectorResult.selections[index])
            try! renderer.replaceStream(
                formats: formats,
                stream: sampleStream,
                startPosition: readingPeriodHolder.getStartPositionRendererTime(),
                offset: readingPeriodHolder.renderPositionOffset,
                mediaPeriodId: readingPeriodHolder.info.id
            )

            return true
        } else if renderer.isEnded() {
            disableRenderer(renderer: renderer, mediaClock: mediaClock)
            if !rendererShouldBeEnabled || isPrewarming {
                maybeResetRenderer(resetPrimary: renderer === primaryRenderer)
            }

            return true
        } else {
            return false
        }
    }

    func formats(from newSelection: SETrackSelection?) -> [Format] {
        guard let newSelection else { return [] }

        return (0..<newSelection.trackGroup.length).map { newSelection.format(for: $0) }
    }

    func isRendererEnabled(renderer: SERenderer) -> Bool {
        renderer.getState() != .disabled
    }

    private func rendererReading(from period: MediaPeriodHolder?) -> SERenderer? {
        guard let period, let stream = period.sampleStreams[index] else { return nil }

        if primaryRenderer.getStream() === stream {
            return primaryRenderer
        } else if let secondaryRenderer, secondaryRenderer.getStream() === stream {
            return secondaryRenderer
        }

        return nil
    }
}

extension RenderersHolder {
    enum RendererPrewarmingState {
        case notPrewarmingUsingPrimary
        case notPrewarmingUsingSecondary
        case prewarmingPrimary
        case transitioningToSecondary
        case transitioningToPrimary
    }
}
