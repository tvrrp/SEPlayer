//
//  BinarySearchSeeker.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.08.2026.
//

import CoreMedia

/// A seeker that looks for a given timestamp from an input.
public protocol TimestampSeeker {
    /// Searches a limited window of the provided input for a target timestamp. The size of the
    /// window is implementation specific, but should be small enough such that it's reasonable for
    /// multiple such reads to occur during a seek operation.
    func searchForTimestamp(
        input: any ExtractorInput,
        targetTimestamp: CMTime,
        _ isolation: isolated any Actor
    ) async throws -> TimestampSearchResult

    /// Called when a seek operation finishes.
    func onSeekFinished(_ isolation: isolated any Actor)
}

public extension TimestampSeeker {
    func onSeekFinished(_ isolation: isolated any Actor) {}
}

/// Represents possible search results for `TimestampSeeker.searchForTimestamp`.
public enum TimestampSearchResult {
    /// The search found a timestamp that it deems close enough to the given target.
    case targetFound(bytePosition: Int)
    /// The search found only timestamps larger than the target timestamp.
    case overestimated(timestamp: CMTime, bytePosition: Int)
    /// The search found only timestamps smaller than the target timestamp.
    case underestimated(timestamp: CMTime, bytePosition: Int)
    /// The search didn't find any timestamps.
    case noTimestamp
}

/// A converter that converts seek time in stream time into target timestamp for the
/// `BinarySearchSeeker`.
public protocol SeekTimestampConverter {
    /// Converts a seek time into target timestamp for the `BinarySearchSeeker`.
    func timeToTargetTime(_ time: CMTime) -> CMTime
}

/// A `SeekTimestampConverter` implementation that returns the seek time itself as the timestamp
/// for a seek time position.
public struct DefaultSeekTimestampConverter: SeekTimestampConverter {
    public init() {}
    public func timeToTargetTime(_ time: CMTime) -> CMTime { time }
}

/// A seeker that supports seeking within a stream by searching for the target frame using binary
/// search.
///
/// This seeker operates on a stream that contains multiple frames (or samples). Each frame is
/// associated with some kind of timestamps, such as stream time, or frame indices. Given a target
/// seek time, the seeker will find the corresponding target timestamp, and perform a search
/// operation within the stream to identify the target frame and return the byte position in the
/// stream of the target frame.
public class BinarySearchSeeker {
    /// When seeking within the source, if the offset is smaller than or equal to this value, the
    /// seek operation will be performed using a skip operation. Otherwise, the source will be
    /// reloaded at the new seek position.
    private static let maxSkipBytes = 256 * 1024

    /// The smallest step between time positions, which keeps a search range from collapsing.
    static let timePositionEpsilon = CMTime(value: 1, timescale: 90_000)

    public let seekMap: BinarySearchSeekMap
    let timestampSeeker: any TimestampSeeker
    var seekOperationParams: SeekOperationParams?

    private let minimumSearchRange: Int

    init(
        seekTimestampConverter: any SeekTimestampConverter,
        timestampSeeker: any TimestampSeeker,
        duration: CMTime,
        floorTimePosition: CMTime,
        ceilingTimePosition: CMTime,
        floorBytePosition: Int,
        ceilingBytePosition: Int,
        approxBytesPerFrame: Int,
        minimumSearchRange: Int
    ) {
        self.timestampSeeker = timestampSeeker
        self.minimumSearchRange = minimumSearchRange
        self.seekMap = BinarySearchSeekMap(
            seekTimestampConverter: seekTimestampConverter,
            duration: duration,
            floorTimePosition: floorTimePosition,
            ceilingTimePosition: ceilingTimePosition,
            floorBytePosition: floorBytePosition,
            ceilingBytePosition: ceilingBytePosition,
            approxBytesPerFrame: approxBytesPerFrame
        )
    }

    /// Sets the target time within the stream to seek to.
    public final func setSeekTarget(time: CMTime) {
        if let seekOperationParams, seekOperationParams.seekTime == time {
            return
        }
        seekOperationParams = createSeekParams(targetTime: time)
    }

    /// Returns whether the last operation set by `setSeekTarget(time:)` is still pending.
    public final var isSeeking: Bool { seekOperationParams != nil }

    /// Continues to handle the pending seek operation.
    public func handlePendingSeek(
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> ExtractorReadResult {
        while true {
            guard var params = seekOperationParams else {
                throw BinarySearchSeekerError.noPendingSeek
            }
            let floorPosition = params.floorBytePosition
            let ceilingPosition = params.ceilingBytePosition
            let searchPosition = params.nextSearchBytePosition

            if ceilingPosition - floorPosition <= minimumSearchRange {
                // The seeking range is too small, so we can just continue from the floor position.
                markSeekOperationFinished(
                    foundTargetFrame: false,
                    resultPosition: floorPosition,
                    isolation
                )
                return seekToPosition(input: input, position: floorPosition, isolation)
            }
            if try !skipInputUntilPosition(input: input, position: searchPosition, isolation) {
                return seekToPosition(input: input, position: searchPosition, isolation)
            }

            input.resetPeekPosition(isolation)
            let result = try await timestampSeeker.searchForTimestamp(
                input: input,
                targetTimestamp: params.targetTimePosition,
                isolation
            )

            switch result {
            case let .overestimated(timestamp, bytePosition):
                params.updateSeekCeiling(
                    ceilingTimePosition: timestamp,
                    ceilingBytePosition: bytePosition
                )
                seekOperationParams = params
            case let .underestimated(timestamp, bytePosition):
                params.updateSeekFloor(
                    floorTimePosition: timestamp,
                    floorBytePosition: bytePosition
                )
                seekOperationParams = params
            case let .targetFound(bytePosition):
                try skipInputUntilPosition(input: input, position: bytePosition, isolation)
                markSeekOperationFinished(
                    foundTargetFrame: true,
                    resultPosition: bytePosition,
                    isolation
                )
                return seekToPosition(input: input, position: bytePosition, isolation)
            case .noTimestamp:
                // We can't find any timestamp in the search range from the search position.
                // Give up, and just continue reading from the last search position in this case.
                markSeekOperationFinished(
                    foundTargetFrame: false,
                    resultPosition: searchPosition,
                    isolation
                )
                return seekToPosition(input: input, position: searchPosition, isolation)
            }
        }
    }

    func createSeekParams(targetTime: CMTime) -> SeekOperationParams {
        SeekOperationParams(
            seekTime: targetTime,
            targetTimePosition: seekMap.timeToTargetTime(targetTime),
            floorTimePosition: seekMap.floorTimePosition,
            ceilingTimePosition: seekMap.ceilingTimePosition,
            floorBytePosition: seekMap.floorBytePosition,
            ceilingBytePosition: seekMap.ceilingBytePosition,
            approxBytesPerFrame: seekMap.approxBytesPerFrame
        )
    }

    final func markSeekOperationFinished(
        foundTargetFrame: Bool,
        resultPosition: Int,
        _ isolation: isolated any Actor
    ) {
        seekOperationParams = nil
        timestampSeeker.onSeekFinished(isolation)
        onSeekOperationFinished(
            foundTargetFrame: foundTargetFrame,
            resultPosition: resultPosition,
            isolation
        )
    }

    func onSeekOperationFinished(
        foundTargetFrame: Bool,
        resultPosition: Int,
        _ isolation: isolated any Actor
    ) {
        // Do nothing.
    }

    @discardableResult
    final func skipInputUntilPosition(
        input: any ExtractorInput,
        position: Int,
        _ isolation: isolated any Actor
    ) throws -> Bool {
        let bytesToSkip = position - input.getPosition(isolation)
        if bytesToSkip >= 0, bytesToSkip <= Self.maxSkipBytes {
            try input.skip(length: bytesToSkip, isolation)
            return true
        }
        return false
    }

    final func seekToPosition(
        input: any ExtractorInput,
        position: Int,
        _ isolation: isolated any Actor
    ) -> ExtractorReadResult {
        if position == input.getPosition(isolation) {
            .continueRead
        } else {
            .seek(offset: position)
        }
    }
}

public enum BinarySearchSeekerError: Error {
    case noPendingSeek
}

extension BinarySearchSeeker {
    /// Contains parameters for a pending seek operation by `BinarySearchSeeker`.
    ///
    /// This holds parameters for a binary-search for the `targetTimePosition` in the range
    /// [floorPosition, ceilingPosition).
    struct SeekOperationParams {
        let seekTime: CMTime
        let targetTimePosition: CMTime
        private let approxBytesPerFrame: Int

        private(set) var floorTimePosition: CMTime
        private(set) var ceilingTimePosition: CMTime
        private(set) var floorBytePosition: Int
        private(set) var ceilingBytePosition: Int
        private(set) var nextSearchBytePosition: Int

        /// Returns the next position in the stream to search for target frame, given
        /// [floorBytePosition, ceilingBytePosition), with corresponding
        /// [floorTimePosition, ceilingTimePosition).
        static func calculateNextSearchBytePosition(
            targetTimePosition: CMTime,
            floorTimePosition: CMTime,
            ceilingTimePosition: CMTime,
            floorBytePosition: Int,
            ceilingBytePosition: Int,
            approxBytesPerFrame: Int
        ) -> Int {
            let floorTimePlusOne = CMTimeAdd(floorTimePosition, timePositionEpsilon)
            if floorBytePosition + 1 >= ceilingBytePosition || floorTimePlusOne >= ceilingTimePosition {
                return floorBytePosition
            }
            let seekTimeDuration = CMTimeSubtract(targetTimePosition, floorTimePosition)
            let timeRange = CMTimeSubtract(ceilingTimePosition, floorTimePosition)
            let estimatedBytesPerTimeUnit = Double(ceilingBytePosition - floorBytePosition)
                / timeRange.seconds
            // It's better to under-estimate rather than over-estimate, because the extractor
            // input can skip forward easily, but cannot rewind easily (it may require a new
            // connection to be made).
            // Therefore, we should reduce the estimated position by some amount, so it will
            // converge to the correct frame earlier.
            let bytesToSkip = Int(seekTimeDuration.seconds * estimatedBytesPerTimeUnit)
            let confidenceInterval = bytesToSkip / 20
            let estimatedFramePosition = floorBytePosition + bytesToSkip - approxBytesPerFrame
            let estimatedPosition = estimatedFramePosition - confidenceInterval
            return min(max(estimatedPosition, floorBytePosition), ceilingBytePosition - 1)
        }

        init(
            seekTime: CMTime,
            targetTimePosition: CMTime,
            floorTimePosition: CMTime,
            ceilingTimePosition: CMTime,
            floorBytePosition: Int,
            ceilingBytePosition: Int,
            approxBytesPerFrame: Int
        ) {
            self.seekTime = seekTime
            self.targetTimePosition = targetTimePosition
            self.floorTimePosition = floorTimePosition
            self.ceilingTimePosition = ceilingTimePosition
            self.floorBytePosition = floorBytePosition
            self.ceilingBytePosition = ceilingBytePosition
            self.approxBytesPerFrame = approxBytesPerFrame
            self.nextSearchBytePosition = Self.calculateNextSearchBytePosition(
                targetTimePosition: targetTimePosition,
                floorTimePosition: floorTimePosition,
                ceilingTimePosition: ceilingTimePosition,
                floorBytePosition: floorBytePosition,
                ceilingBytePosition: ceilingBytePosition,
                approxBytesPerFrame: approxBytesPerFrame
            )
        }

        /// Updates the floor constraints (inclusive) of the seek operation.
        mutating func updateSeekFloor(floorTimePosition: CMTime, floorBytePosition: Int) {
            self.floorTimePosition = floorTimePosition
            self.floorBytePosition = floorBytePosition
            updateNextSearchBytePosition()
        }

        /// Updates the ceiling constraints (exclusive) of the seek operation.
        mutating func updateSeekCeiling(ceilingTimePosition: CMTime, ceilingBytePosition: Int) {
            self.ceilingTimePosition = ceilingTimePosition
            self.ceilingBytePosition = ceilingBytePosition
            updateNextSearchBytePosition()
        }

        private mutating func updateNextSearchBytePosition() {
            nextSearchBytePosition = Self.calculateNextSearchBytePosition(
                targetTimePosition: targetTimePosition,
                floorTimePosition: floorTimePosition,
                ceilingTimePosition: ceilingTimePosition,
                floorBytePosition: floorBytePosition,
                ceilingBytePosition: ceilingBytePosition,
                approxBytesPerFrame: approxBytesPerFrame
            )
        }
    }

    /// A `SeekMap` implementation that returns the estimated byte location from
    /// `SeekOperationParams.calculateNextSearchBytePosition` for each `getSeekPoints(for:)` query.
    public final class BinarySearchSeekMap: SeekMap {
        private let seekTimestampConverter: any SeekTimestampConverter
        private let duration: CMTime
        let floorTimePosition: CMTime
        let ceilingTimePosition: CMTime
        let floorBytePosition: Int
        let ceilingBytePosition: Int
        let approxBytesPerFrame: Int

        init(
            seekTimestampConverter: any SeekTimestampConverter,
            duration: CMTime,
            floorTimePosition: CMTime,
            ceilingTimePosition: CMTime,
            floorBytePosition: Int,
            ceilingBytePosition: Int,
            approxBytesPerFrame: Int
        ) {
            self.seekTimestampConverter = seekTimestampConverter
            self.duration = duration
            self.floorTimePosition = floorTimePosition
            self.ceilingTimePosition = ceilingTimePosition
            self.floorBytePosition = floorBytePosition
            self.ceilingBytePosition = ceilingBytePosition
            self.approxBytesPerFrame = approxBytesPerFrame
        }

        public func isSeekable() -> Bool { true }

        public func getDuration() -> CMTime { duration }

        public func getSeekPoints(for time: CMTime) -> SeekPoints {
            let nextSearchPosition = SeekOperationParams.calculateNextSearchBytePosition(
                targetTimePosition: seekTimestampConverter.timeToTargetTime(time),
                floorTimePosition: floorTimePosition,
                ceilingTimePosition: ceilingTimePosition,
                floorBytePosition: floorBytePosition,
                ceilingBytePosition: ceilingBytePosition,
                approxBytesPerFrame: approxBytesPerFrame
            )
            return SeekPoints(first: SeekPoints.SeekPoint(time: time, position: nextSearchPosition))
        }

        func timeToTargetTime(_ time: CMTime) -> CMTime {
            seekTimestampConverter.timeToTargetTime(time)
        }
    }
}
