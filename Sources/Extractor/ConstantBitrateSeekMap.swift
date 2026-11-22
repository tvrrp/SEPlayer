//
//  ConstantBitrateSeekMap.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ConstantBitrateSeekMap
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

/// A seek map for a stream of a constant bitrate: positions are proportional to times.
public struct ConstantBitrateSeekMap: SeekMap {
    let inputLength: Int?
    let firstFramePosition: Int
    let frameSize: Int
    let bitrate: Int
    let allowSeeksIfLengthUnknown: Bool

    private let dataSize: Int?

    /// - Parameters:
    ///   - inputLength: The length of the stream, if it is known.
    ///   - firstFramePosition: Where the first frame starts.
    ///   - bitrate: The bitrate, in bits per second.
    ///   - frameSize: The size of a frame, to which seek positions are rounded; `nil` if frames vary.
    ///   - allowSeeksIfLengthUnknown: Whether a stream of an unknown length can be seeked in.
    public init(
        inputLength: Int?,
        firstFramePosition: Int,
        bitrate: Int,
        frameSize: Int?,
        allowSeeksIfLengthUnknown: Bool = false
    ) {
        self.inputLength = inputLength
        self.firstFramePosition = firstFramePosition
        self.frameSize = frameSize ?? 1
        self.bitrate = bitrate
        self.allowSeeksIfLengthUnknown = allowSeeksIfLengthUnknown
        dataSize = inputLength.map { $0 - firstFramePosition }
    }

    public func isSeekable() -> Bool {
        dataSize != nil || allowSeeksIfLengthUnknown
    }

    public func getDuration() -> CMTime {
        guard let inputLength else { return .invalid }
        return time(at: inputLength)
    }

    public func getSeekPoints(for time: CMTime) -> SeekPoints {
        guard dataSize != nil || allowSeeksIfLengthUnknown else {
            return SeekPoints(first: .init(time: .zero, position: firstFramePosition))
        }
        let seekFramePosition = framePosition(for: time)
        let seekTime = self.time(at: seekFramePosition)
        let seekPoint = SeekPoints.SeekPoint(time: seekTime, position: seekFramePosition)
        guard let inputLength, seekTime < time, seekFramePosition + frameSize < inputLength else {
            return SeekPoints(first: seekPoint)
        }
        let secondPosition = seekFramePosition + frameSize
        return SeekPoints(first: seekPoint, second: .init(time: self.time(at: secondPosition), position: secondPosition))
    }

    /// The time of the byte at `position`.
    public func time(at position: Int) -> CMTime {
        guard bitrate > 0 else { return .zero }
        let bits = Int64(max(0, position - firstFramePosition)) * 8
        return CMTime(value: bits * 1_000_000 / Int64(bitrate), timescale: 1_000_000)
    }

    private func framePosition(for time: CMTime) -> Int {
        let microseconds = Int64(max(time.seconds, 0) * 1_000_000)
        var positionOffset = Int(microseconds * Int64(bitrate) / (1_000_000 * 8))
        positionOffset = positionOffset / frameSize * frameSize
        if let dataSize {
            positionOffset = min(positionOffset, dataSize - frameSize)
        }
        return firstFramePosition + max(positionOffset, 0)
    }
}
