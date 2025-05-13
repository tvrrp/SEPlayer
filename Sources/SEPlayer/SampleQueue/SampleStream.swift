//
//  SampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol SampleStream {
    func isReady() -> Bool
    func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult
    func skipData(position: Int64) -> Int
}

enum SampleStreamReadResult: Equatable {
    case nothingRead
    case didReadFormat(format: CMFormatDescription)
    case didReadBuffer
}

struct ReadFlags: OptionSet {
    let rawValue: UInt8
    static let peek = ReadFlags(rawValue: 1)
    static let requireFormat = ReadFlags(rawValue: 1 << 1)
    static let omitSampleData = ReadFlags(rawValue: 1 << 2)
}
