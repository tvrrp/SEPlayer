//
//  FrameReleaseHelper.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import UIKit

final class VideoFrameReleaseHelper {
    private let queue: Queue
    private let displayLink: DisplayLinkProvider
    private var frameRateEstimator: FixedFrameRateEstimator

    private var started: Bool = false
    private var frameRate: Float = .zero
    private var playbackSpeed: Float = 1.0
    private var vsyncDuration: Int64?
    private var vsyncOffset: Int64 = .zero

    private var frameIndex: Int64 = 0
    private var pendingLastAdjustedFrameIndex: Int64?
    private var pendingLastAdjustedReleaseTime: Int64 = .zero
    private var lastAdjustedFrameIndex: Int64?
    private var lastAdjustedReleaseTime: Int64 = .zero

    private var displayLinkFrameRate: Float?

    init(queue: Queue, displayLink: DisplayLinkProvider) {
        self.queue = queue
        self.displayLink = displayLink
        self.frameRateEstimator = FixedFrameRateEstimator()
    }

    func start() {
        assert(queue.isCurrent())
        displayLink.addObserver()
        started = true
        resetAdjustment()

        updateDefaultDisplayRefreshRateParams()
        updateDisplayLinkFrameRate(forceUpdate: false)
    }

    func reset() {
        resetAdjustment()
    }

    func playbackSpeedDidChanged(new playbackSpeed: Float) {
        assert(queue.isCurrent())
        self.playbackSpeed = playbackSpeed
        resetAdjustment()
        updateDisplayLinkFrameRate(forceUpdate: false)
    }

    func frameRateDidChanged(new frameRate: Float) {
        assert(queue.isCurrent())
        self.frameRate = frameRate
        frameRateEstimator.reset()
        updateMediaFrameRate()
    }

    func onNextFrame(framePresentationTime: Int64) {
        assert(queue.isCurrent())
        if let pendingLastAdjustedFrameIndex {
            lastAdjustedFrameIndex = pendingLastAdjustedFrameIndex
            lastAdjustedReleaseTime = pendingLastAdjustedReleaseTime
        }
        frameIndex += 1
        frameRateEstimator.onNextFrame(framePresentationTime: framePresentationTime * 1000)
        updateMediaFrameRate()
    }

    func stop() {
        assert(queue.isCurrent())
        started = false
        displayLink.removeObserver()
    }

    func adjustReleaseTime(releaseTime: Int64) -> Int64 {
        var adjustedReleaseTime = releaseTime

        if let lastAdjustedFrameIndex, frameRateEstimator.isSynced {
            let frameDuration = frameRateEstimator.frameDuration
            let candidateAdjustedReleaseTime = lastAdjustedReleaseTime
                + Int64((Double(frameDuration * (frameIndex - lastAdjustedFrameIndex))) / Double(playbackSpeed))

            if adjustmentAllowed(unadjustedReleaseTime: releaseTime, adjustedReleaseTime: candidateAdjustedReleaseTime) {
                adjustedReleaseTime = candidateAdjustedReleaseTime
            } else {
                resetAdjustment()
            }
        }
        pendingLastAdjustedFrameIndex = frameIndex
        pendingLastAdjustedReleaseTime = adjustedReleaseTime

        updateDefaultDisplayRefreshRateParams()
        guard let vsyncDuration, let sampledVsyncTime = displayLink.sampledVsyncTime else { return adjustedReleaseTime }

        let vsyncCount = (releaseTime - sampledVsyncTime) / vsyncDuration
        let snappedTime = sampledVsyncTime + (vsyncDuration * vsyncCount)
        return snappedTime + vsyncOffset
    }

    private func resetAdjustment() {
        frameIndex = 0
        lastAdjustedFrameIndex = nil
        pendingLastAdjustedFrameIndex = nil
    }

    private func adjustmentAllowed(unadjustedReleaseTime: Int64, adjustedReleaseTime: Int64) -> Bool {
        abs(unadjustedReleaseTime - adjustedReleaseTime) <= .maxAllowedAdjustment
    }

    private func updateMediaFrameRate() {
        let candidateFrameRate = frameRateEstimator.isSynced ? frameRateEstimator.frameRate : frameRate
        guard candidateFrameRate != displayLinkFrameRate else { return }

        var shouldUpdate = false
        if let candidateFrameRate, let displayLinkFrameRate {
            let candidateIsHighConfidence = if let matchingFrameDuration = frameRateEstimator.matchingFrameDuration {
                matchingFrameDuration >= .minimumMatchingFrameDurationForHignConfidence
            } else {
                false
            }
            let minimumChangeForUpdate: Float = candidateIsHighConfidence
                ? .minFrameRateChangeHighConfidience
                : .minFrameRateChangeLowConfidience
            shouldUpdate = abs(candidateFrameRate - displayLinkFrameRate) >= minimumChangeForUpdate
        } else if let candidateFrameRate {
            shouldUpdate = true
        } else {
            shouldUpdate = frameRateEstimator.framesWithoutSyncCount >= .minimumFramesWithoutSyncToClearFrameRate
        }

        if shouldUpdate {
            displayLinkFrameRate = candidateFrameRate
            updateDisplayLinkFrameRate(forceUpdate: false)
        }
    }

    private func updateDisplayLinkFrameRate(forceUpdate: Bool) {

    }

    private func updateDefaultDisplayRefreshRateParams() {
        guard let vsyncDuration = displayLink.vsyncDuration else { return }
        vsyncOffset = vsyncDuration * 80 / 100
        self.vsyncDuration = vsyncDuration
    }
}

private extension Int64 {
    static let maxAllowedAdjustment: Int64 = 20_000_000
    static let minimumMatchingFrameDurationForHignConfidence: Int64 = 5_000_000_000
}

private extension Int {
    static let minimumFramesWithoutSyncToClearFrameRate = 2 * FixedFrameRateEstimator.consecutiveMatchingFrameDurationsForSync
}

private extension Float {
    static let minFrameRateChangeHighConfidience: Float = 0.02
    static let minFrameRateChangeLowConfidience: Float = 1
}
