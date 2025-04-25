//
//  SampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol SampleStream {
    var format: CMFormatDescription { get }
    func isReady() -> Bool
    @discardableResult
    func readData(to decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult
    func readData(to decoderInput: CMBlockBuffer, flags: ReadFlags) throws -> SampleStreamReadResult
    @discardableResult
    func skipData(to time: Int64) -> Int
}

struct ReadFlags: OptionSet {
    let rawValue: UInt8
    static let peek = ReadFlags(rawValue: 1)
    static let requireFormat = ReadFlags(rawValue: 1 << 1)
    static let omitSampleData = ReadFlags(rawValue: 1 << 2)
}

enum SampleStreamReadResult: Equatable {
    case nothingRead
    case didReadFormat(format: CMFormatDescription)
    case didReadBuffer(metadata: SampleMetadata)

    static func == (lhs: SampleStreamReadResult, rhs: SampleStreamReadResult) -> Bool {
        if case .nothingRead = lhs, case .nothingRead = rhs { return true }
        if case .didReadFormat = lhs, case .didReadFormat = rhs { return true }
        if case .didReadBuffer = lhs, case .didReadBuffer = rhs { return true }

        return false
    }
}

enum SampleStreamReadResult2: Equatable {
    case nothingRead
    case didReadFormat(format: CMFormatDescription)
    case didReadBuffer
}

protocol SampleStream2 {
    func isReady() -> Bool
    func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult2
    func skipData(position: Int64) -> Int
}
