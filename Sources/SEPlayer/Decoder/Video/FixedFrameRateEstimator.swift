//
//  FixedFrameRateEstimator.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import Foundation

struct FixedFrameRateEstimator {
    private var currentMatcher = Matcher()
    private var candidateMatcher = Matcher()
    private var candidateMatcherActive: Bool = false
    private var switchToCandidateMatcherWhenSynced: Bool = false
    private var lastFramePresentationTime: Int64?

    var isSynced: Bool { currentMatcher.isSynced }
    var framesWithoutSyncCount: Int = 0

    var matchingFrameDuration: Int64? {
        isSynced ? currentMatcher.matchingFrameDuration : nil
    }

    var frameDuration: Int64 {
        isSynced ? currentMatcher.frameDuration : .zero
    }

    var frameRate: Float? {
        isSynced ? Float(Double(Int64.nanosecondsPerSecond) / Double(currentMatcher.frameDuration)) : .zero
    }

    mutating func reset() {
        currentMatcher.reset()
        candidateMatcher.reset()
        candidateMatcherActive = false
        lastFramePresentationTime = nil
        framesWithoutSyncCount = 0
    }

    mutating func onNextFrame(framePresentationTime: Int64) {
        currentMatcher.onNextFrame(framePresentationTime: framePresentationTime)
        if currentMatcher.isSynced && !switchToCandidateMatcherWhenSynced {
            candidateMatcherActive = true
        } else if let lastFramePresentationTime {
            if !candidateMatcherActive || candidateMatcher.isLastFrameOutlier {
                candidateMatcher.reset()
                candidateMatcher.onNextFrame(framePresentationTime: framePresentationTime)
            }
            candidateMatcherActive = true
            candidateMatcher.onNextFrame(framePresentationTime: framePresentationTime)
        }

        if candidateMatcherActive && candidateMatcher.isSynced {
            let previousMatcher = currentMatcher
            currentMatcher = candidateMatcher
            candidateMatcher = previousMatcher
            candidateMatcherActive = false
            switchToCandidateMatcherWhenSynced = false
        }
        lastFramePresentationTime = framePresentationTime
        framesWithoutSyncCount = currentMatcher.isSynced ? 0 : framesWithoutSyncCount + 1
    }
}

extension FixedFrameRateEstimator {
    struct Matcher {
        var matchingFrameDuration: Int64 = 0

        private var firstFramePresentation: Int64 = 0
        private var firstFrameDuration: Int64 = 0
        private var lastFramePresentation: Int64 = 0
        private var frameCount: Int = 0
        private var matchingFrameCount: Int = 0
        private var recentFrameOutlierFlags: [Bool]
        private var recentFrameOutlierCount: Int = 0

        var isSynced: Bool {
            frameCount > FixedFrameRateEstimator.consecutiveMatchingFrameDurationsForSync && recentFrameOutlierCount == 0
        }

        var isLastFrameOutlier: Bool {
            if frameCount == 0 {
                return false
            }
            return recentFrameOutlierFlags[recentFrameOutlierIndex(for: frameCount - 1)]
        }

        var frameDuration: Int64 {
            matchingFrameCount == 0 ? 0 : (matchingFrameDuration / Int64(matchingFrameCount))
        }

        init() {
            recentFrameOutlierFlags = .init(repeating: false, count: FixedFrameRateEstimator.consecutiveMatchingFrameDurationsForSync)
        }

        mutating func reset() {
            frameCount = 0
            matchingFrameCount = 0
            matchingFrameDuration = 0
            recentFrameOutlierCount = 0
            recentFrameOutlierFlags = .init(repeating: false, count: FixedFrameRateEstimator.consecutiveMatchingFrameDurationsForSync)
        }

        mutating func onNextFrame(framePresentationTime: Int64) {
            if frameCount == 0 {
                firstFramePresentation = framePresentationTime
            } else if frameCount == 1 {
                firstFrameDuration = framePresentationTime - firstFramePresentation
                matchingFrameDuration = firstFrameDuration
                matchingFrameCount = 1
            } else {
                let lastFrameDuration = framePresentationTime - lastFramePresentation
                let recentFrameOutlierIndex = recentFrameOutlierIndex(for: frameCount)

                if abs(lastFrameDuration - firstFrameDuration) <= .maxMatchingFrameDifference {
                    matchingFrameCount += 1
                    matchingFrameDuration += lastFrameDuration
                    if recentFrameOutlierFlags[recentFrameOutlierIndex] {
                        recentFrameOutlierFlags[recentFrameOutlierIndex] = false
                        recentFrameOutlierCount -= 1
                    }
                } else {
                    if !recentFrameOutlierFlags[recentFrameOutlierIndex] {
                        recentFrameOutlierFlags[recentFrameOutlierIndex] = true
                        recentFrameOutlierCount += 1
                    }
                }
            }

            frameCount += 1
            lastFramePresentation = framePresentationTime
        }

        private func recentFrameOutlierIndex(for frameCount: Int) -> Int {
            return frameCount % FixedFrameRateEstimator.consecutiveMatchingFrameDurationsForSync
        }
    }
}

extension FixedFrameRateEstimator {
    static let consecutiveMatchingFrameDurationsForSync: Int = 15
}

private extension Int64 {
    static let maxMatchingFrameDifference: Int64 = 1_000_000
    static let nanosecondsPerSecond: Int64 = 1_000_000_000
}
