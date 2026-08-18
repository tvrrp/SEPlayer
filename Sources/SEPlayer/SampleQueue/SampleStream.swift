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
    func isEqual(to other: any SampleStream) -> Bool
}

extension SampleStream {
    func isEqual(to other: any SampleStream) -> Bool {
        self === other
    }
}

@frozen public enum SampleStreamReadResult: Equatable {
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
