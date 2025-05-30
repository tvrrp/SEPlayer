//
//  VideoFrameReleaseControl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import CoreMedia.CMSync

struct VideoFrameReleaseControl {
    weak var frameTimingEvaluator: FrameTimingEvaluator?
    private var frameReleaseHelper: VideoFrameReleaseHelper

    private var started: Bool = false
    private var firstFrameState: FirstFrameState = .notRenderedOnlyAllowedIfStarted
    private var initialPosition: Int64?
    private var lastReleaseRealtime: Int64 = 0
    private var lastPresentationTime: Int64 = 0

    private var joiningDeadline: Int64?
    private var joiningRenderNextFrameImmediately: Bool = false

    private var playbackSpeed: Float = 1.0
    private let clock: CMClock

    init(
        queue: Queue,
        clock: CMClock,
        displayLink: DisplayLinkProvider
    ) {
        frameReleaseHelper = VideoFrameReleaseHelper(queue: queue, displayLink: displayLink)
        self.clock = clock
    }

    mutating func enable(releaseFirstFrameBeforeStarted: Bool) {
        firstFrameState = releaseFirstFrameBeforeStarted ? .notRendered : .notRenderedOnlyAllowedIfStarted
    }

    mutating func disable() {
        firstFrameState = .notRenderedOnlyAllowedIfStarted
    }

    mutating func start() {
        started = true
        lastReleaseRealtime = clock.microseconds
        frameReleaseHelper.start()
    }

    mutating func stop() {
        started = false
        frameReleaseHelper.stop()
    }

    func setFrameRate(_ frameRate: Float) {
        frameReleaseHelper.frameRateDidChanged(new: frameRate)
    }

    @discardableResult
    mutating func didReleaseFrame() -> Bool {
        let firstFrame = firstFrameState != .rendered
        firstFrameState = .rendered
        lastReleaseRealtime = clock.microseconds
        return firstFrame
    }

    mutating func allowReleaseFirstFrameBeforeStarted() {
        if firstFrameState == .notRenderedOnlyAllowedIfStarted {
            firstFrameState = .notRendered
        }
    }

    func isReady() -> Bool {
        // TODO: joining
        return firstFrameState == .rendered
    }

    mutating func frameReleaseAction(
        presentationTime: Int64,
        position: Int64,
        elapsedRealtime: Int64,
        outputStreamStartPosition: Int64,
        isDecodeOnlyFrame: Bool,
        isLastFrame: Bool
    ) -> FrameReleaseAction {
        guard let frameTimingEvaluator else {
            assertionFailure(); return .tryAgainLater
        }
        if initialPosition == nil {
            initialPosition = position
        }

        if lastPresentationTime != presentationTime {
            frameReleaseHelper.onNextFrame(framePresentationTime: presentationTime)
            lastPresentationTime = presentationTime
        }

        var earlyTime = calculateEarlyTime(
            position: position,
            elapsedRealtime: elapsedRealtime,
            framePresentationTime: presentationTime
        )

        if isDecodeOnlyFrame && !isLastFrame {
            return .skip
        }

        if shouldForceRelease(position: position, earlyTime: earlyTime, outputStreamStartPosition: outputStreamStartPosition) {
            return .immediately
        }

        if !started || position == initialPosition {
            return .tryAgainLater
        }

        let clockTime = clock.nanoseconds
        let releaseTime = frameReleaseHelper.adjustReleaseTime(releaseTime: clockTime + (earlyTime * 1000))
        earlyTime = (releaseTime - clockTime) / 1000
        let treatDropAsSkip = joiningDeadline != nil && !joiningRenderNextFrameImmediately

        if frameTimingEvaluator.shouldIgnoreFrame(earlyTime: earlyTime,
                                                  position: position,
                                                  elapsedRealtime: elapsedRealtime,
                                                  isLast: isLastFrame,
                                                  treatDroppedAsSkipped: treatDropAsSkip) {
            return .ignore
        } else if frameTimingEvaluator.shouldDropFrame(earlyTime: earlyTime,
                                                       elapsedSinceLastRelease: elapsedRealtime,
                                                       isLast: isLastFrame) {
            return treatDropAsSkip ? .skip : .drop
        } else if earlyTime > .maxEarlyTreashold {
            return .tryAgainLater
        }

        return .scheduled(releaseTime: releaseTime)
    }

    mutating func reset() {
        frameReleaseHelper.reset()
        lastPresentationTime = .zero
        initialPosition = .zero
        firstFrameState = .notRendered
        joiningDeadline = nil
    }

    mutating func setPlaybackSpeed(_ speed: Float) {
        guard speed != playbackSpeed else { return }
        self.playbackSpeed = speed
        frameReleaseHelper.playbackSpeedDidChanged(new: speed)
    }

    private func calculateEarlyTime(position: Int64, elapsedRealtime: Int64, framePresentationTime: Int64) -> Int64 {
        var earlyUs = Int64((Double(framePresentationTime - position) / Double(playbackSpeed)))
        if started {
            earlyUs -= clock.microseconds - elapsedRealtime
        }

        return earlyUs
    }

    private func shouldForceRelease(position: Int64, earlyTime: Int64, outputStreamStartPosition: Int64) -> Bool {
        guard let frameTimingEvaluator else {
            assertionFailure(); return false
        }
        switch firstFrameState {
        case .notRenderedOnlyAllowedIfStarted:
            return started
        case .notRendered:
            return true
        case .rendered:
            let elapsedTimeSinceLastRelease = clock.microseconds - lastReleaseRealtime
            return started && frameTimingEvaluator.shouldForceReleaseFrame(
                earlyTime: earlyTime, elapsedSinceLastRelease: elapsedTimeSinceLastRelease
            )
        }
    }
}

extension VideoFrameReleaseControl {
    protocol FrameTimingEvaluator: AnyObject {
        func shouldForceReleaseFrame(earlyTime: Int64, elapsedSinceLastRelease: Int64) -> Bool
        func shouldDropFrame(earlyTime: Int64, elapsedSinceLastRelease: Int64, isLast: Bool) -> Bool
        func shouldIgnoreFrame(
            earlyTime: Int64,
            position: Int64,
            elapsedRealtime: Int64,
            isLast: Bool,
            treatDroppedAsSkipped: Bool
        ) -> Bool
    }

    enum FrameReleaseAction {
        case immediately
        case scheduled(releaseTime: Int64)
        case drop
        case skip
        case ignore
        case tryAgainLater
    }

    enum FirstFrameState {
        case notRenderedOnlyAllowedIfStarted
        case notRendered
        case rendered
    }
}

private extension Int64 {
    static let maxEarlyTreashold: Int64 = 50_000
}
