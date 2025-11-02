//
//  SampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public protocol SampleStream: AnyObject {
    func isReady() -> Bool
    func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult
    func skipData(position: Int64) -> Int
}

@frozen public enum SampleStreamReadResult: Equatable {
    case nothingRead
    case didReadFormat(format: Format)
    case didReadBuffer
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
