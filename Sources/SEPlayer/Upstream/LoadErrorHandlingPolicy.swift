//
//  LoadErrorHandlingPolicy.swift
//  SEPlayer
//
//  Created by tvrrp on 11.02.2026.
//

import CoreMedia
import Dispatch
import DataSource
import SEPlayerCommon

/// What a failed load can fall back to instead of retrying.
public enum FallbackType {
    /// Another location of the same media, as another CDN.
    case location
    /// Another track of the same content, as another variant of an HLS stream.
    case track
}

/// A failed load.
public struct LoadErrorInfo {
    /// The type of the data that failed to load.
    public let dataType: DataType
    /// The error the load failed with.
    public let error: Error
    /// How many times in a row the load failed, this time included.
    public let errorCount: Int

    public init(dataType: DataType, error: Error, errorCount: Int) {
        self.dataType = dataType
        self.error = error
        self.errorCount = errorCount
    }
}

/// The alternatives a failed load has.
public struct FallbackOptions {
    public let numberOfLocations: Int
    public let numberOfExcludedLocations: Int
    public let numberOfTracks: Int
    public let numberOfExcludedTracks: Int

    public init(numberOfLocations: Int, numberOfExcludedLocations: Int, numberOfTracks: Int, numberOfExcludedTracks: Int) {
        self.numberOfLocations = numberOfLocations
        self.numberOfExcludedLocations = numberOfExcludedLocations
        self.numberOfTracks = numberOfTracks
        self.numberOfExcludedTracks = numberOfExcludedTracks
    }

    /// Whether something is left to fall back to after excluding the one that failed.
    public func isFallbackAvailable(_ type: FallbackType) -> Bool {
        switch type {
        case .location: numberOfLocations - numberOfExcludedLocations > 1
        case .track: numberOfTracks - numberOfExcludedTracks > 1
        }
    }
}

/// A fallback for a failed load: what to exclude, and for how long.
public struct FallbackSelection {
    public let type: FallbackType
    public let exclusionDuration: CMTime

    public init(type: FallbackType, exclusionDuration: CMTime) {
        self.type = type
        self.exclusionDuration = exclusionDuration
    }
}

/// Decides what happens after a load fails: whether it falls back to another track or location, retries after a
/// delay, or fails.
///
/// A load that retries doesn't stop playback while there is media buffered. Playback fails once the buffer runs out
/// and the load failed more than ``getMinimumLoadableRetryCount(dataType:)`` times in a row, or right away when the
/// error is fatal.
public protocol LoadErrorHandlingPolicy: AnyObject {
    /// The fallback to exclude a failed track or location for, or `nil` to retry or fail instead.
    func getFallbackSelection(for fallbackOptions: FallbackOptions, loadErrorInfo: LoadErrorInfo) -> FallbackSelection?
    /// The delay before the load retries, or `nil` if the error is fatal and the load must not retry.
    func getRetryDelay(for loadErrorInfo: LoadErrorInfo) -> DispatchTimeInterval?
    /// How many times in a row a load may fail before its error stops playback once the buffer runs out.
    func getMinimumLoadableRetryCount(dataType: DataType) -> Int
}

/// Retries a load that may succeed again with a growing delay, and fails right away on what loading again can't fix:
/// malformed or unsupported media, a missing file, a forbidden connection, a range past the end of the resource.
///
/// A track that answers 403, 404, 410, 416, 500 or 503 is excluded for a minute when another one can play instead.
open class DefaultLoadErrorHandlingPolicy: LoadErrorHandlingPolicy {
    /// How many times in a row a load may fail before its error stops playback.
    public static let defaultMinLoadableRetryCount = 3
    /// How many times in a row the load of a progressive live stream may fail: it can't refill what it missed.
    public static let defaultMinLoadableRetryCountProgressiveLive = 6
    /// How long a track that failed to load is excluded for.
    public static let defaultTrackExclusionDuration = CMTime(value: 60, timescale: 1)
    /// How long a location that failed to load is excluded for.
    public static let defaultLocationExclusionDuration = CMTime(value: 300, timescale: 1)

    private let minimumLoadableRetryCount: Int?

    /// - Parameter minimumLoadableRetryCount: How many times in a row a load may fail before its error stops
    ///   playback, or `nil` for the default of the data type.
    public init(minimumLoadableRetryCount: Int? = nil) {
        self.minimumLoadableRetryCount = minimumLoadableRetryCount
    }

    open func getFallbackSelection(for fallbackOptions: FallbackOptions, loadErrorInfo: LoadErrorInfo) -> FallbackSelection? {
        guard isEligibleForFallback(loadErrorInfo.error) else { return nil }
        // A location is the same media, so it goes first.
        if fallbackOptions.isFallbackAvailable(.location) {
            return FallbackSelection(type: .location, exclusionDuration: Self.defaultLocationExclusionDuration)
        }
        if fallbackOptions.isFallbackAvailable(.track) {
            return FallbackSelection(type: .track, exclusionDuration: Self.defaultTrackExclusionDuration)
        }
        return nil
    }

    open func getRetryDelay(for loadErrorInfo: LoadErrorInfo) -> DispatchTimeInterval? {
        guard !isFatal(loadErrorInfo.error) else { return nil }
        return .milliseconds(min((loadErrorInfo.errorCount - 1) * 1000, 5000))
    }

    open func getMinimumLoadableRetryCount(dataType: DataType) -> Int {
        if let minimumLoadableRetryCount { return minimumLoadableRetryCount }
        return dataType == .mediaProgressiveLive
            ? Self.defaultMinLoadableRetryCountProgressiveLive
            : Self.defaultMinLoadableRetryCount
    }

    /// Whether the error is fatal, so the load must not retry: what it loads, or the way it loads it, can't work.
    open func isFatal(_ error: Error) -> Bool {
        if DataSourceError.isCausedByPositionOutOfRange(error) { return true }
        if (error as? URLSessionDataSourceError)?.errorReason?.isPermanent == true { return true }
        if error is UnexpectedStateError || error is UnsupportedOperationError { return true }

        switch (error as? PlaybackErrorCodeProviding)?.errorCode {
        case .parsingContainerMalformed?, .parsingManifestMalformed?,
             .parsingContainerUnsupported?, .parsingManifestUnsupported?,
             .ioFileNotFound?, .ioNoPermission?, .ioCleartextNotPermitted?, .ioReadPositionOutOfRange?:
            return true
        default:
            return false
        }
    }

    /// Whether another track or location may succeed where the load failed.
    open func isEligibleForFallback(_ error: Error) -> Bool {
        guard let error = error as? InvalidResponseCodeError else {
            return false
        }
        return [403, 404, 410, 416, 500, 503].contains(error.responseCode)
    }
}
