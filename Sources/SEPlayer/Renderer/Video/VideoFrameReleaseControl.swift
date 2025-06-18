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
    private let allowedJoiningTimeMs: Int64

    private var started: Bool = false
    private var firstFrameState: FirstFrameState
    private var initialPositionUs: Int64
    private var lastReleaseRealtimeUs: Int64
    private var lastPresentationTimeUs: Int64

    private var joiningDeadlineMs: Int64
    private var joiningRenderNextFrameImmediately: Bool = false

    private var playbackSpeed: Float
    private let clock: CMClock

    init(
        queue: Queue,
        clock: CMClock,
        displayLink: DisplayLinkProvider,
        allowedJoiningTimeMs: Int64
    ) {
        self.clock = clock
        self.allowedJoiningTimeMs = allowedJoiningTimeMs
        frameReleaseHelper = VideoFrameReleaseHelper(queue: queue, displayLink: displayLink)
        firstFrameState = .notRenderedOnlyAllowedIfStarted
        initialPositionUs = .timeUnset
        lastReleaseRealtimeUs = .zero
        lastPresentationTimeUs = .timeUnset
        joiningDeadlineMs = .timeUnset
        playbackSpeed = 1.0
    }

    mutating func enable(releaseFirstFrameBeforeStarted: Bool) {
        firstFrameState = releaseFirstFrameBeforeStarted ? .notRendered : .notRenderedOnlyAllowedIfStarted
    }

    mutating func disable() {
        lowerFirstFrameState(to: .notRenderedOnlyAllowedIfStarted)
    }

    mutating func start() {
        guard !started else { return }
        started = true
        lastReleaseRealtimeUs = clock.microseconds
        frameReleaseHelper.start()
    }

    mutating func stop() {
        guard started else { return }
        started = false
        joiningDeadlineMs = .timeUnset
        frameReleaseHelper.stop()
    }

    mutating func processedStreamChanged() {
        lowerFirstFrameState(to: .notRenderedAfterStreamChanged)
    }

    func setFrameRate(_ frameRate: Float) {
        frameReleaseHelper.frameRateDidChanged(new: frameRate)
    }

    @discardableResult
    mutating func didReleaseFrame() -> Bool {
        let firstFrame = firstFrameState != .rendered
        firstFrameState = .rendered
        lastReleaseRealtimeUs = clock.microseconds
        return firstFrame
    }

    mutating func allowReleaseFirstFrameBeforeStarted() {
        if firstFrameState == .notRenderedOnlyAllowedIfStarted {
            firstFrameState = .notRendered
        }
    }

    mutating func isReady(rendererOtherwiseReady: Bool) -> Bool {
        if rendererOtherwiseReady, firstFrameState == .rendered {
            // Ready. If we were joining then we've now joined, so clear the joining deadline.
            joiningDeadlineMs = .timeUnset
            return true
        } else if joiningDeadlineMs == .timeUnset {
            // Not joining.
            return false
        } else if clock.milliseconds < joiningDeadlineMs {
            // Joining and still withing the deadline.
            return true
        } else {
            // The joining deadline has been exceeded. Give up and clear the deadline.
            joiningDeadlineMs = .timeUnset
            return false
        }
    }

    mutating func join(renderNextFrameImmediately: Bool) {
        joiningRenderNextFrameImmediately = renderNextFrameImmediately
        joiningDeadlineMs = allowedJoiningTimeMs > 0 ? (clock.milliseconds + allowedJoiningTimeMs) : .timeUnset
    }

    mutating func frameReleaseAction(
        presentationTimeUs: Int64,
        positionUs: Int64,
        elapsedRealtimeUs: Int64,
        outputStreamStartPositionUs: Int64,
        isDecodeOnlyFrame: Bool,
        isLastFrame: Bool
    ) -> FrameReleaseAction {
        guard let frameTimingEvaluator else {
            assertionFailure(); return .tryAgainLater
        }
        if initialPositionUs == .timeUnset {
            initialPositionUs = positionUs
        }

        if lastPresentationTimeUs != presentationTimeUs {
            frameReleaseHelper.onNextFrame(framePresentationTime: presentationTimeUs)
            lastPresentationTimeUs = presentationTimeUs
        }

        var earlyTimeUs = calculateEarlyTime(
            positionUs: positionUs,
            elapsedRealtimeUs: elapsedRealtimeUs,
            framePresentationTimeUs: presentationTimeUs
        )

//        print("💔 will calculate")
//        print("💔 presentationTimeUs = \(presentationTimeUs)")
//        print("💔 positionUs = \(positionUs)")
//        print("💔 elapsedRealtimeUs = \(elapsedRealtimeUs)")
//        print("💔 outputStreamStartPositionUs = \(outputStreamStartPositionUs)")
//        print("💔 isDecodeOnlyFrame = \(isDecodeOnlyFrame)")
//        print("💔 isLastFrame = \(isLastFrame)")
        if isDecodeOnlyFrame && !isLastFrame {
//            print("✅ result skip")
            return .skip
        }

        if shouldForceRelease(positionUs: positionUs, earlyTimeUs: earlyTimeUs, outputStreamStartPositionUs: outputStreamStartPositionUs) {
//            print("✅ result immediately")
            return .immediately
        }

        if !started || positionUs == initialPositionUs {
//            print("✅ result tryAgainLater")
            return .tryAgainLater
        }

        let clockTimeNs = clock.nanoseconds
        let releaseTimeNs = frameReleaseHelper.adjustReleaseTime(releaseTime: clockTimeNs + (earlyTimeUs * 1000))
        earlyTimeUs = (releaseTimeNs - clockTimeNs) / 1000
        let treatDropAsSkip = joiningDeadlineMs != .timeUnset && !joiningRenderNextFrameImmediately

        if frameTimingEvaluator.shouldIgnoreFrame(earlyTimeUs: earlyTimeUs,
                                                  positionUs: positionUs,
                                                  elapsedRealtimeUs: elapsedRealtimeUs,
                                                  isLast: isLastFrame,
                                                  treatDroppedAsSkipped: treatDropAsSkip) {
//            print("✅ result ignore")
            return .ignore
        } else if frameTimingEvaluator.shouldDropFrame(earlyTimeUs: earlyTimeUs,
                                                       elapsedSinceLastReleaseUs: elapsedRealtimeUs,
                                                       isLast: isLastFrame) {
            return treatDropAsSkip ? .skip : .drop
        } else if earlyTimeUs > .maxEarlyTreashold {
//            print("✅ result tryAgainLater")
            return .tryAgainLater
        }

        return .scheduled(releaseTimeNs: releaseTimeNs)
    }

    mutating func reset() {
        frameReleaseHelper.reset()
        lastPresentationTimeUs = .timeUnset
        initialPositionUs = .timeUnset
        lowerFirstFrameState(to: .notRendered)
        joiningDeadlineMs = .timeUnset
    }

    mutating func setPlaybackSpeed(_ speed: Float) {
        guard speed != playbackSpeed else { return }
        self.playbackSpeed = speed
        frameReleaseHelper.playbackSpeedDidChanged(new: speed)
    }

    private mutating func lowerFirstFrameState(to state: FirstFrameState) {
        firstFrameState = min(firstFrameState, state)
    }

    private func calculateEarlyTime(positionUs: Int64, elapsedRealtimeUs: Int64, framePresentationTimeUs: Int64) -> Int64 {
        var earlyUs = Int64((Double(framePresentationTimeUs - positionUs) / Double(playbackSpeed)))
        if started {
            earlyUs -= clock.microseconds - elapsedRealtimeUs
        }

        return earlyUs
    }

    private func shouldForceRelease(positionUs: Int64, earlyTimeUs: Int64, outputStreamStartPositionUs: Int64) -> Bool {
        guard let frameTimingEvaluator else {
            assertionFailure(); return false
        }

        guard joiningDeadlineMs == .timeUnset || joiningRenderNextFrameImmediately else {
            return false
        }

        switch firstFrameState {
        case .notRenderedOnlyAllowedIfStarted:
            return started
        case .notRendered:
            return true
        case .notRenderedAfterStreamChanged:
            return positionUs >= outputStreamStartPositionUs
        case .rendered:
            let elapsedTimeSinceLastReleaseUs = clock.microseconds - lastReleaseRealtimeUs
            return started && frameTimingEvaluator.shouldForceReleaseFrame(
                earlyTimeUs: earlyTimeUs, elapsedSinceLastReleaseUs: elapsedTimeSinceLastReleaseUs
            )
        }
    }
}

extension VideoFrameReleaseControl {
    protocol FrameTimingEvaluator: AnyObject {
        func shouldForceReleaseFrame(earlyTimeUs: Int64, elapsedSinceLastReleaseUs: Int64) -> Bool
        func shouldDropFrame(earlyTimeUs: Int64, elapsedSinceLastReleaseUs: Int64, isLast: Bool) -> Bool
        func shouldIgnoreFrame(
            earlyTimeUs: Int64,
            positionUs: Int64,
            elapsedRealtimeUs: Int64,
            isLast: Bool,
            treatDroppedAsSkipped: Bool
        ) -> Bool
    }

    enum FrameReleaseAction {
        case immediately
        case scheduled(releaseTimeNs: Int64)
        case drop
        case skip
        case ignore
        case tryAgainLater
    }

    enum FirstFrameState: Int, Comparable {
        case notRenderedOnlyAllowedIfStarted = 0
        case notRendered = 1
        case notRenderedAfterStreamChanged = 2
        case rendered = 3

        static func < (lhs: VideoFrameReleaseControl.FirstFrameState, rhs: VideoFrameReleaseControl.FirstFrameState) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }
}

private extension Int64 {
    static let maxEarlyTreashold: Int64 = 50_000
}
