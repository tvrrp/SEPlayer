//
//  LivePlaybackSpeedControl.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.LivePlaybackSpeedControl
//    androidx.media3.exoplayer.DefaultLivePlaybackSpeedControl
//  Copyright (C) 2020 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Adjusts the playback speed of live streams to keep a target offset from the live edge.
public protocol LivePlaybackSpeedControl: AnyObject {
    /// Sets the live configuration of the media, with its target offset and the speeds it allows.
    func setLiveConfiguration(_ liveConfiguration: MediaItem.LiveConfiguration)

    /// Overrides the target offset of the media, as after a seek inside the live window; `.invalid` goes back to it.
    func setTargetLiveOffsetOverride(_ liveOffset: CMTime)

    /// Called when playback ran out of media and buffers again: the target moves away from the live edge.
    func notifyRebuffer()

    /// The playback speed to keep the target offset.
    ///
    /// - Parameters:
    ///   - liveOffset: The current offset from the live edge.
    ///   - bufferedDuration: How much media is buffered ahead of the playback position.
    func adjustedPlaybackSpeed(liveOffset: CMTime, bufferedDuration: CMTime) -> Float

    /// The target offset from the live edge, or `.invalid` if there is none.
    var targetLiveOffset: CMTime { get }
}

/// A ``LivePlaybackSpeedControl`` that changes the speed in proportion to how far playback is from the target offset.
///
/// A change of speed interrupts the audio for a moment, so the speed changes as rarely as possible: once playback is
/// half a second or more off the target, a speed in proportion to the offset error holds until playback reaches the
/// target, and the speed goes back to 1 then. A correction costs two changes, however long it takes.
///
/// The target starts at the media's offset. It moves away from the live edge by half a second at every rebuffer, and
/// moves back towards the media's offset while the buffer allows: it stays three standard deviations away from the
/// smallest offset the buffer could have given, so that a speed-up doesn't run the buffer dry.
public final class DefaultLivePlaybackSpeedControl: LivePlaybackSpeedControl {
    /// The speed range used when the media doesn't give one.
    public static let fallbackMinPlaybackSpeed: Float = 0.97
    public static let fallbackMaxPlaybackSpeed: Float = 1.03

    private let clock: SEClock
    private var fallbackMinPlaybackSpeed: Float
    private var fallbackMaxPlaybackSpeed: Float
    /// How often the speed may change.
    private let minUpdateInterval: CMTime
    /// The change of speed per second of offset error.
    private let proportionalControlFactor: Double
    /// How far the target moves away from the live edge at every rebuffer.
    private var targetLiveOffsetRebufferDelta: CMTime
    private let minPossibleLiveOffsetSmoothingFactor: Double
    /// An offset error below which a correction ends.
    private let maxLiveOffsetErrorForUnitSpeed: CMTime
    /// An offset error from which a correction starts.
    private let minLiveOffsetErrorForSpeedChange: CMTime

    // `.invalid` when unset.
    private var mediaConfigurationTargetLiveOffset: CMTime = .invalid
    private var targetLiveOffsetOverride: CMTime = .invalid
    private var minTargetLiveOffset: CMTime = .invalid
    private var maxTargetLiveOffset: CMTime = .invalid
    private var idealTargetLiveOffset: CMTime = .invalid
    private var currentTargetLiveOffset: CMTime = .invalid
    private var minPlaybackSpeed: Float
    private var maxPlaybackSpeed: Float
    private var adjustedPlaybackSpeed: Float = 1
    private var lastPlaybackSpeedUpdateTime: CMTime = .invalid
    private var smoothedMinPossibleLiveOffset: CMTime = .invalid
    private var smoothedMinPossibleLiveOffsetDeviation: CMTime = .invalid

    public init(
        clock: SEClock? = nil,
        fallbackMinPlaybackSpeed: Float = DefaultLivePlaybackSpeedControl.fallbackMinPlaybackSpeed,
        fallbackMaxPlaybackSpeed: Float = DefaultLivePlaybackSpeedControl.fallbackMaxPlaybackSpeed,
        minUpdateInterval: CMTime = CMTime(value: 1, timescale: 1),
        proportionalControlFactor: Double = 0.1,
        targetLiveOffsetRebufferDelta: CMTime = CMTime(value: 500, timescale: 1000),
        minPossibleLiveOffsetSmoothingFactor: Double = 0.999,
        maxLiveOffsetErrorForUnitSpeed: CMTime = CMTime(value: 20, timescale: 1000),
        minLiveOffsetErrorForSpeedChange: CMTime = CMTime(value: 500, timescale: 1000)
    ) {
        self.clock = clock ?? DefaultSEClock.shared
        self.fallbackMinPlaybackSpeed = fallbackMinPlaybackSpeed
        self.fallbackMaxPlaybackSpeed = fallbackMaxPlaybackSpeed
        self.minUpdateInterval = minUpdateInterval
        self.proportionalControlFactor = proportionalControlFactor
        self.targetLiveOffsetRebufferDelta = targetLiveOffsetRebufferDelta
        self.minPossibleLiveOffsetSmoothingFactor = minPossibleLiveOffsetSmoothingFactor
        self.maxLiveOffsetErrorForUnitSpeed = maxLiveOffsetErrorForUnitSpeed
        self.minLiveOffsetErrorForSpeedChange = minLiveOffsetErrorForSpeedChange
        minPlaybackSpeed = fallbackMinPlaybackSpeed
        maxPlaybackSpeed = fallbackMaxPlaybackSpeed
    }

    public var targetLiveOffset: CMTime { currentTargetLiveOffset }

    public func setLiveConfiguration(_ liveConfiguration: MediaItem.LiveConfiguration) {
        mediaConfigurationTargetLiveOffset = liveConfiguration.targetOffset
        minTargetLiveOffset = liveConfiguration.minOffset
        maxTargetLiveOffset = liveConfiguration.maxOffset
        minPlaybackSpeed = liveConfiguration.minPlaybackSpeed ?? fallbackMinPlaybackSpeed
        maxPlaybackSpeed = liveConfiguration.maxPlaybackSpeed ?? fallbackMaxPlaybackSpeed
        if minPlaybackSpeed == 1, maxPlaybackSpeed == 1 {
            // The speed can't change: there is nothing to adjust.
            mediaConfigurationTargetLiveOffset = .invalid
        }
        maybeResetTargetLiveOffset()
    }

    public func setTargetLiveOffsetOverride(_ liveOffset: CMTime) {
        targetLiveOffsetOverride = liveOffset
        maybeResetTargetLiveOffset()
    }

    public func notifyRebuffer() {
        guard currentTargetLiveOffset.isNumeric else { return }
        currentTargetLiveOffset = currentTargetLiveOffset + targetLiveOffsetRebufferDelta
        if maxTargetLiveOffset.isNumeric, currentTargetLiveOffset > maxTargetLiveOffset {
            currentTargetLiveOffset = maxTargetLiveOffset
        }
        lastPlaybackSpeedUpdateTime = .invalid
    }

    public func adjustedPlaybackSpeed(liveOffset: CMTime, bufferedDuration: CMTime) -> Float {
        guard mediaConfigurationTargetLiveOffset.isNumeric, liveOffset.isNumeric, bufferedDuration.isNumeric else {
            return 1
        }

        updateSmoothedMinPossibleLiveOffset(liveOffset: liveOffset, bufferedDuration: bufferedDuration)

        let now = clock.time
        if lastPlaybackSpeedUpdateTime.isNumeric, now - lastPlaybackSpeedUpdateTime < minUpdateInterval {
            return adjustedPlaybackSpeed
        }
        lastPlaybackSpeedUpdateTime = now

        adjustTargetLiveOffset(liveOffset: liveOffset)
        guard currentTargetLiveOffset.isNumeric else { return 1 }
        let previousSpeed = adjustedPlaybackSpeed
        let liveOffsetError = liveOffset - currentTargetLiveOffset
        if adjustedPlaybackSpeed == 1 {
            if CMTimeAbsoluteValue(liveOffsetError) >= minLiveOffsetErrorForSpeedChange {
                let calculatedSpeed = Float(1 + proportionalControlFactor * liveOffsetError.seconds)
                adjustedPlaybackSpeed = min(max(calculatedSpeed, minPlaybackSpeed), maxPlaybackSpeed)
            }
        } else {
            // The speed holds until playback reaches the target, or passes it.
            let reachedTarget = adjustedPlaybackSpeed > 1 ? liveOffsetError <= .zero : liveOffsetError >= .zero
            if reachedTarget || CMTimeAbsoluteValue(liveOffsetError) < maxLiveOffsetErrorForUnitSpeed {
                adjustedPlaybackSpeed = 1
            }
        }
        if adjustedPlaybackSpeed != previousSpeed {
            SELogger.debug(.playback, "Live offset \(liveOffset.seconds)s, target \(currentTargetLiveOffset.seconds)s, buffered \(bufferedDuration.seconds)s: speed \(previousSpeed) → \(adjustedPlaybackSpeed)")
        }
        return adjustedPlaybackSpeed
    }

    // MARK: - Private

    private func maybeResetTargetLiveOffset() {
        var idealOffset = CMTime.invalid
        if mediaConfigurationTargetLiveOffset.isNumeric {
            idealOffset = targetLiveOffsetOverride.isNumeric ? targetLiveOffsetOverride : mediaConfigurationTargetLiveOffset
            if minTargetLiveOffset.isNumeric, idealOffset < minTargetLiveOffset { idealOffset = minTargetLiveOffset }
            if maxTargetLiveOffset.isNumeric, idealOffset > maxTargetLiveOffset { idealOffset = maxTargetLiveOffset }
        }
        guard !Self.isSame(idealTargetLiveOffset, idealOffset) else { return }
        idealTargetLiveOffset = idealOffset
        currentTargetLiveOffset = idealOffset
        smoothedMinPossibleLiveOffset = .invalid
        smoothedMinPossibleLiveOffsetDeviation = .invalid
        lastPlaybackSpeedUpdateTime = .invalid
    }

    private func updateSmoothedMinPossibleLiveOffset(liveOffset: CMTime, bufferedDuration: CMTime) {
        let minPossibleLiveOffset = liveOffset - bufferedDuration
        guard smoothedMinPossibleLiveOffset.isNumeric, smoothedMinPossibleLiveOffsetDeviation.isNumeric else {
            smoothedMinPossibleLiveOffset = minPossibleLiveOffset
            smoothedMinPossibleLiveOffsetDeviation = .zero
            return
        }
        // The largest, not the average: it tracks what is safely possible.
        let newSmoothed = max(minPossibleLiveOffset, smooth(smoothedMinPossibleLiveOffset, minPossibleLiveOffset))
        smoothedMinPossibleLiveOffset = newSmoothed
        smoothedMinPossibleLiveOffsetDeviation = smooth(
            smoothedMinPossibleLiveOffsetDeviation,
            CMTimeAbsoluteValue(minPossibleLiveOffset - newSmoothed)
        )
    }

    private func adjustTargetLiveOffset(liveOffset: CMTime) {
        guard currentTargetLiveOffset.isNumeric, idealTargetLiveOffset.isNumeric,
              smoothedMinPossibleLiveOffset.isNumeric, smoothedMinPossibleLiveOffsetDeviation.isNumeric else {
            return
        }
        // Three standard deviations from the smallest possible offset: safe more than 99% of the time.
        let safeOffset = smoothedMinPossibleLiveOffset + CMTimeMultiply(smoothedMinPossibleLiveOffsetDeviation, multiplier: 3)
        if currentTargetLiveOffset > safeOffset {
            // The target can come closer, towards the ideal or the safe offset, by no more than the speed-up allows.
            let decrementToOffsetCurrentSpeed = CMTimeMultiplyByFloat64(minUpdateInterval, multiplier: Double(adjustedPlaybackSpeed - 1))
            let decrementToIncreaseSpeed = CMTimeMultiplyByFloat64(minUpdateInterval, multiplier: Double(maxPlaybackSpeed - 1))
            let maxDecrement = decrementToOffsetCurrentSpeed + decrementToIncreaseSpeed
            currentTargetLiveOffset = max(safeOffset, idealTargetLiveOffset, currentTargetLiveOffset - maxDecrement)
        } else {
            // Below the safe offset, the target moves out to it; slowing down now gets there.
            let slowDown = CMTime(
                seconds: Double(max(0, adjustedPlaybackSpeed - 1)) / proportionalControlFactor,
                preferredTimescale: liveOffset.timescale
            )
            let offsetWhenSlowingDownNow = liveOffset - slowDown
            currentTargetLiveOffset = min(max(offsetWhenSlowingDownNow, currentTargetLiveOffset), safeOffset)
            if maxTargetLiveOffset.isNumeric, currentTargetLiveOffset > maxTargetLiveOffset {
                currentTargetLiveOffset = maxTargetLiveOffset
            }
        }
    }

    private func smooth(_ smoothedValue: CMTime, _ newValue: CMTime) -> CMTime {
        CMTimeMultiplyByFloat64(smoothedValue, multiplier: minPossibleLiveOffsetSmoothingFactor)
            + CMTimeMultiplyByFloat64(newValue, multiplier: 1 - minPossibleLiveOffsetSmoothingFactor)
    }

    /// Whether both are unset, or the same time.
    private static func isSame(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        lhs.isNumeric == rhs.isNumeric && (!lhs.isNumeric || lhs == rhs)
    }
}
