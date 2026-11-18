//
//  SampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Decoder
import SEPlayerCommon

public protocol SampleStream: AnyObject, TriggerableSampleStream {
    var bufferedAheadDuration: CMTime { get }
    func isReady() -> Bool
    func maybeThrowError() throws
    func readData(readFlags: ReadFlags) throws -> SampleStreamReadResult
    func skipData(position: CMTime) throws -> Int
    /// Repositions only this stream in retained data. Failure must leave it unchanged.
    func seekWithinBuffer(to position: CMTime) throws -> SampleStreamSeekResult
    func isEqual(to other: any SampleStream) -> Bool
}

public enum SampleStreamSeekResult: Equatable {
    case success(startPosition: CMTime)
    case unavailable
    case unsupported
}

public extension SampleStream {
    func seekWithinBuffer(to position: CMTime) throws -> SampleStreamSeekResult { .unsupported }
}

extension SampleStream {
    func isEqual(to other: any SampleStream) -> Bool {
        self === other
    }
}

@frozen
public enum SampleStreamReadResult: Equatable {
    case nothingRead
    case didReadFormat(format: Format)
    case didReadBuffer(_ buffer: CMSampleBuffer)
}

public struct ReadFlags: OptionSet {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let peek = ReadFlags(rawValue: 1)
    public static let requireFormat = ReadFlags(rawValue: 1 << 1)
    public static let omitSampleData = ReadFlags(rawValue: 1 << 2)
}
