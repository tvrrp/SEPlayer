//
//  Mp3Seekers.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.mp3.Seeker
//    androidx.media3.extractor.mp3.ConstantBitrateSeeker
//    androidx.media3.extractor.mp3.XingFrame
//    androidx.media3.extractor.mp3.XingSeeker
//    androidx.media3.extractor.mp3.VbriSeeker
//    androidx.media3.extractor.mp3.MlltSeeker
//  Copyright (C) 2016, 2018, 2019, 2024 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// A seek map of an MP3 stream that also maps positions to times.
protocol Mp3Seeker: SeekMap {
    /// Where the audio frames start.
    var dataStartPosition: Int { get }
    /// Where the audio frames end, if it is known.
    var dataEndPosition: Int? { get }
    /// The average bitrate, in bits per second, if it is known.
    var averageBitrate: Int? { get }

    /// The time of the frame at `position`.
    func time(at position: Int) -> CMTime
}

extension Mp3Seeker {
    /// The average bitrate of `byteCount` bytes that play for `duration`, or `nil` if it can't be computed.
    static func averageBitrate(byteCount: Int?, duration: CMTime) -> Int? {
        guard let byteCount, byteCount > 0, duration.isNumeric, duration > .zero else {
            return nil
        }
        return Int(Double(byteCount) * 8 / duration.seconds)
    }
}

/// A seeker for a stream of a constant bitrate.
struct ConstantBitrateSeeker: Mp3Seeker {
    let dataEndPosition: Int?

    var dataStartPosition: Int { seekMap.firstFramePosition }
    var averageBitrate: Int? { seekMap.bitrate }

    private let seekMap: ConstantBitrateSeekMap
    /// The duration another source gives, as an Info frame, or `.invalid` for the one of the bitrate.
    private let duration: CMTime

    init(
        inputLength: Int?,
        firstFramePosition: Int,
        bitrate: Int,
        frameSize: Int?,
        allowSeeksIfLengthUnknown: Bool,
        duration: CMTime = .invalid
    ) {
        seekMap = ConstantBitrateSeekMap(
            inputLength: inputLength,
            firstFramePosition: firstFramePosition,
            bitrate: bitrate,
            frameSize: frameSize,
            allowSeeksIfLengthUnknown: allowSeeksIfLengthUnknown
        )
        self.duration = duration
        dataEndPosition = inputLength
    }

    init(inputLength: Int?, firstFramePosition: Int, header: MpegAudioUtil.Header, allowSeeksIfLengthUnknown: Bool) {
        self.init(
            inputLength: inputLength,
            firstFramePosition: firstFramePosition,
            bitrate: header.bitrate,
            frameSize: header.frameSize,
            allowSeeksIfLengthUnknown: allowSeeksIfLengthUnknown
        )
    }

    func isSeekable() -> Bool { seekMap.isSeekable() }

    func getDuration() -> CMTime {
        duration.isNumeric ? duration : seekMap.getDuration()
    }

    func getSeekPoints(for time: CMTime) -> SeekPoints {
        // Seeking to the end goes to the last frame.
        guard duration.isNumeric, time >= duration, let dataEndPosition else {
            return seekMap.getSeekPoints(for: time)
        }
        let lastFramePosition = max(seekMap.firstFramePosition, dataEndPosition - seekMap.frameSize)
        let frameDuration = seekMap.time(at: seekMap.firstFramePosition + seekMap.frameSize)
        return SeekPoints(first: .init(time: max(.zero, duration - frameDuration), position: lastFramePosition))
    }

    func time(at position: Int) -> CMTime {
        seekMap.time(at: position)
    }

    /// This seeker with the stream ending at `dataEndPosition`, where the last frame was found to end.
    func withDataEndPosition(_ dataEndPosition: Int) -> ConstantBitrateSeeker {
        ConstantBitrateSeeker(
            inputLength: dataEndPosition,
            firstFramePosition: seekMap.firstFramePosition,
            bitrate: seekMap.bitrate,
            frameSize: seekMap.frameSize,
            allowSeeksIfLengthUnknown: seekMap.allowSeeksIfLengthUnknown,
            duration: duration
        )
    }
}

/// The Xing or Info frame of a VBR or CBR MP3 stream: the number of frames, the size and a table of contents.
struct XingFrame {
    let header: MpegAudioUtil.Header
    let frameCount: Int?
    let dataSize: Int?
    /// Where each hundredth of the duration is in the data, in 256ths of its size.
    let tableOfContents: [Int]?
    let encoderDelay: Int?
    let encoderPadding: Int?

    /// The duration of the stream, without the gapless samples, or `.invalid` if the frame doesn't count its frames.
    var duration: CMTime {
        guard let frameCount, frameCount > 0 else { return .invalid }
        var sampleCount = Int64(frameCount) * Int64(header.samplesPerFrame)
        if let encoderDelay, let encoderPadding {
            sampleCount -= Int64(encoderDelay + encoderPadding)
        }
        guard sampleCount > 0 else { return .invalid }
        return CMTime(value: sampleCount - 1, timescale: CMTimeScale(header.sampleRate))
    }

    /// - Parameter frame: The frame, from after the `Xing` or `Info` tag.
    init(header: MpegAudioUtil.Header, frame: inout BlockBufferReader) throws {
        self.header = header
        let flags = try frame.readInt(as: UInt32.self)
        frameCount = flags & 0x01 != 0 ? try Int(frame.readInt(as: UInt32.self)) : nil
        dataSize = flags & 0x02 != 0 ? try Int(frame.readInt(as: UInt32.self)) : nil
        if flags & 0x04 != 0 {
            tableOfContents = try frame.readBytes(length: Self.tableOfContentsLength).map(Int.init)
        } else {
            tableOfContents = nil
        }
        if flags & 0x08 != 0 {
            try frame.skip(4) // Quality indicator.
        }

        // The LAME extension: the encoder, the replay gain, then the delay and the padding.
        guard frame.readableBytes >= 9 + 2 + 8 + 2 + 3 else {
            encoderDelay = nil
            encoderPadding = nil
            return
        }
        // The encoder; revision and VBR method, lowpass; peak, radio and audiophile gain; flags, bitrate.
        try frame.skip(9 + 2 + 8 + 2)
        // As the encoder wrote them. They fit the system's decoder, which adds no delay of its own.
        let encoderDelayAndPadding = try frame.readUInt24()
        encoderDelay = encoderDelayAndPadding >> 12
        encoderPadding = encoderDelayAndPadding & 0xFFF
    }
}

private extension XingFrame {
    static let tableOfContentsLength = 100
}

/// A seeker on the table of contents of a Xing frame.
struct XingSeeker: Mp3Seeker {
    let averageBitrate: Int?
    let dataEndPosition: Int?

    var dataStartPosition: Int { xingFramePosition + xingFrameSize }

    private let xingFramePosition: Int
    private let xingFrameSize: Int
    private let duration: CMTime
    private let dataSize: Int?
    private let tableOfContents: [Int]?

    init?(xingFrame: XingFrame, position: Int, streamLength: Int?) {
        guard xingFrame.duration.isNumeric else { return nil }
        var dataSize = xingFrame.dataSize
        if let size = xingFrame.dataSize, let streamLength, position + size != streamLength {
            SELogger.info(.rawAudio, "Data size mismatch between stream and Xing frame, using the smaller one")
            dataSize = min(size, streamLength - position)
        }
        xingFramePosition = position
        xingFrameSize = xingFrame.header.frameSize
        duration = xingFrame.duration
        self.dataSize = dataSize
        tableOfContents = xingFrame.tableOfContents
        averageBitrate = Self.averageBitrate(
            byteCount: dataSize.map { $0 - xingFrame.header.frameSize },
            duration: xingFrame.duration
        )
        dataEndPosition = dataSize.map { position + $0 }
    }

    func isSeekable() -> Bool { tableOfContents != nil && dataSize != nil }

    func getDuration() -> CMTime { duration }

    func getSeekPoints(for time: CMTime) -> SeekPoints {
        guard let tableOfContents, let dataSize else {
            return SeekPoints(first: .init(time: .zero, position: dataStartPosition))
        }
        let time = min(max(time, .zero), duration)
        let percent = time.seconds * 100 / duration.seconds
        let scaledPosition: Double
        if percent <= 0 {
            scaledPosition = 0
        } else if percent >= 100 {
            scaledPosition = Self.tableOfContentsScale
        } else {
            let index = Int(percent)
            let previous = Self.scaledPosition(tableOfContents, at: index)
            let next = Self.scaledPosition(tableOfContents, at: index + 1)
            scaledPosition = previous + (percent - Double(index)) * (next - previous)
        }
        var positionOffset = Int((scaledPosition / Self.tableOfContentsScale * Double(dataSize)).rounded())
        positionOffset = min(max(positionOffset, xingFrameSize), dataSize - 1)
        return SeekPoints(first: .init(time: time, position: xingFramePosition + positionOffset))
    }

    func time(at position: Int) -> CMTime {
        let positionOffset = position - xingFramePosition
        guard let tableOfContents, let dataSize, positionOffset > xingFrameSize else {
            return .zero
        }
        let scaledPosition = Double(positionOffset) * Self.tableOfContentsScale / Double(dataSize)
        let index = tableOfContents.lastIndex { Double($0) <= scaledPosition } ?? 0
        let previous = Self.scaledPosition(tableOfContents, at: index)
        let next = Self.scaledPosition(tableOfContents, at: index + 1)
        let fraction = previous == next ? 0 : (scaledPosition - previous) / (next - previous)
        // Each entry of the table is a hundredth of the duration.
        return CMTimeMultiplyByFloat64(duration, multiplier: (Double(index) + fraction) / 100)
    }
}

private extension XingSeeker {
    /// What the positions of the table of contents are fractions of.
    static let tableOfContentsScale = 256.0

    /// The position of entry `index` of the table; the end of the data after its last entry.
    static func scaledPosition(_ tableOfContents: [Int], at index: Int) -> Double {
        index < tableOfContents.count ? Double(tableOfContents[index]) : tableOfContentsScale
    }
}

/// A seeker on the table of contents of a VBRI frame.
struct VbriSeeker: Mp3Seeker {
    let dataStartPosition: Int
    let dataEndPosition: Int?
    let averageBitrate: Int?

    private let times: [CMTime]
    private let positions: [Int]
    private let duration: CMTime

    /// - Parameter frame: The frame, from after the `VBRI` tag.
    init?(inputLength: Int?, position: Int, header: MpegAudioUtil.Header, frame: inout BlockBufferReader) throws {
        try frame.skip(6) // The version, delay and quality.
        let dataSize = try Int(frame.readInt(as: Int32.self))
        let frameCount = try Int64(frame.readInt(as: Int32.self))
        guard frameCount > 0 else { return nil }
        let sampleCount = frameCount * Int64(header.samplesPerFrame)
        let duration = CMTime(value: sampleCount - 1, timescale: CMTimeScale(header.sampleRate))
        let entryCount = try Int(frame.readInt(as: UInt16.self))
        let scale = try Int(frame.readInt(as: UInt16.self))
        let entrySize = try Int(frame.readInt(as: UInt16.self))
        try frame.skip(2)
        guard entryCount > 0 else { return nil }

        let dataStartPosition = position + header.frameSize
        var times = [CMTime]()
        var positions = [Int]()
        var entryPosition = dataStartPosition
        for index in 0 ..< entryCount {
            times.append(CMTimeMultiplyByRatio(duration, multiplier: Int32(index), divisor: Int32(entryCount)))
            positions.append(entryPosition)
            let segmentSize: Int
            switch entrySize {
            case 1: segmentSize = try Int(frame.readInt(as: UInt8.self))
            case 2: segmentSize = try Int(frame.readInt(as: UInt16.self))
            case 3: segmentSize = try frame.readUInt24()
            case 4: segmentSize = try Int(frame.readInt(as: UInt32.self))
            default: return nil
            }
            entryPosition += segmentSize * scale
        }
        var dataEndPosition = dataStartPosition + dataSize
        if dataEndPosition != entryPosition {
            SELogger.warning(.rawAudio, "VBRI bytes and ToC mismatch (using max): seeking will be inaccurate")
            dataEndPosition = max(dataEndPosition, entryPosition)
        }

        self.times = times
        self.positions = positions
        self.duration = duration
        self.dataStartPosition = dataStartPosition
        self.dataEndPosition = dataEndPosition
        averageBitrate = Self.averageBitrate(byteCount: dataEndPosition - dataStartPosition, duration: duration)
    }

    func isSeekable() -> Bool { true }

    func getDuration() -> CMTime { duration }

    func getSeekPoints(for time: CMTime) -> SeekPoints {
        let index = times.lastIndex { $0 <= time } ?? 0
        let seekPoint = SeekPoints.SeekPoint(time: times[index], position: positions[index])
        guard times[index] < time, index < times.count - 1 else {
            return SeekPoints(first: seekPoint)
        }
        return SeekPoints(first: seekPoint, second: .init(time: times[index + 1], position: positions[index + 1]))
    }

    func time(at position: Int) -> CMTime {
        times[positions.lastIndex { $0 <= position } ?? 0]
    }
}

/// A seeker on the reference points of an ID3 `MLLT` frame.
struct MlltSeeker: Mp3Seeker {
    var dataStartPosition: Int { 0 }
    var dataEndPosition: Int? { nil }
    var averageBitrate: Int? { nil }

    private let referencePositions: [Int]
    private let referenceTimesMs: [Int]
    private let duration: CMTime

    /// - Parameter duration: The duration the ID3 tag gives, or `.invalid` for the time of the last reference.
    init(firstFramePosition: Int, mlltFrame: MlltFrame, duration: CMTime) {
        var positions = [firstFramePosition]
        var timesMs = [0]
        for index in mlltFrame.bytesDeviations.indices {
            let position = positions[index] + mlltFrame.bytesBetweenReference + mlltFrame.bytesDeviations[index]
            let timeMs = timesMs[index] + mlltFrame.millisecondsBetweenReference
                + mlltFrame.millisecondsDeviations[index]
            positions.append(position)
            timesMs.append(timeMs)
        }
        referencePositions = positions
        referenceTimesMs = timesMs
        self.duration = duration.isNumeric ? duration : CMTime(value: CMTimeValue(timesMs[timesMs.count - 1]), timescale: 1000)
    }

    func isSeekable() -> Bool { true }

    func getDuration() -> CMTime { duration }

    func getSeekPoints(for time: CMTime) -> SeekPoints {
        // The references end where the stream does.
        let lastReferenceTimeMs = referenceTimesMs[referenceTimesMs.count - 1]
        let timeMs = min(Int(max(time, .zero).seconds * 1000), lastReferenceTimeMs)
        let position = Self.interpolate(timeMs, from: referenceTimesMs, to: referencePositions)
        return SeekPoints(first: .init(time: CMTime(value: CMTimeValue(timeMs), timescale: 1000), position: position))
    }

    func time(at position: Int) -> CMTime {
        let timeMs = Self.interpolate(position, from: referencePositions, to: referenceTimesMs)
        return CMTime(value: CMTimeValue(timeMs), timescale: 1000)
    }
}

private extension MlltSeeker {
    /// The value at `x` on the line between the references around it; the last reference's after it.
    static func interpolate(_ x: Int, from xReferences: [Int], to yReferences: [Int]) -> Int {
        let previousIndex = xReferences.lastIndex { $0 <= x } ?? 0
        let xPrevious = xReferences[previousIndex]
        let yPrevious = yReferences[previousIndex]
        let nextIndex = previousIndex + 1
        guard nextIndex < xReferences.count else { return yPrevious }
        let xNext = xReferences[nextIndex]
        let yNext = yReferences[nextIndex]
        let proportion = xNext == xPrevious ? 0 : Double(x - xPrevious) / Double(xNext - xPrevious)
        return Int(proportion * Double(yNext - yPrevious)) + yPrevious
    }
}

/// Reports audible times and loads ahead of the selected frame for synchronization and decoder preroll.
struct Mp3PlaybackSeekMap: SeekMap {
    let seeker: any Mp3Seeker
    let frameDuration: CMTime
    let delay: CMTime
    let padding: CMTime

    func isSeekable() -> Bool { seeker.isSeekable() }

    func getDuration() -> CMTime {
        let duration = seeker.getDuration()
        return duration.isNumeric ? max(.zero, duration - delay - padding) : duration
    }

    func getSeekPoints(for time: CMTime) -> SeekPoints {
        if time <= .zero {
            return SeekPoints(first: .init(time: .zero, position: seeker.getSeekPoints(for: .zero).first.position))
        }
        let points = seeker.getSeekPoints(for: max(.zero, time + delay))
        func playbackPoint(_ point: SeekPoints.SeekPoint) -> SeekPoints.SeekPoint {
            // A VBR seek can land inside a frame. Allow one frame to regain sync and one to prime.
            let readTime = max(.zero, point.time - frameDuration - frameDuration)
            let position = seeker.getSeekPoints(for: readTime).first.position
            return .init(time: max(.zero, point.time - delay), position: position)
        }
        return SeekPoints(first: playbackPoint(points.first), second: playbackPoint(points.second))
    }
}
