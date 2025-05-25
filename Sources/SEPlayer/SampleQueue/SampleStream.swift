//
//  SampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public protocol SampleStream: AnyObject {
    func isReady() -> Bool
    func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult
    func skipData(position: Int64) -> Int
}

public enum SampleStreamReadResult: Equatable {
    case nothingRead
    case didReadFormat(format: CMFormatDescription)
    case didReadBuffer
}

public struct ReadFlags: OptionSet {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let peek = ReadFlags(rawValue: 1)
    static let requireFormat = ReadFlags(rawValue: 1 << 1)
    static let omitSampleData = ReadFlags(rawValue: 1 << 2)
}
