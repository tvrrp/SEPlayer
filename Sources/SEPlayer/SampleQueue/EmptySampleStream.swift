//
//  EmptySampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.05.2025.
//

final class EmptySampleStream: SampleStream {
    func isReady() -> Bool { true }

    func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult {
        buffer.flags.insert(.endOfStream)
        return .didReadBuffer
    }

    func skipData(position: Int64) -> Int { .zero }
}
