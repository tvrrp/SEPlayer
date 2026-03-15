//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import SEPlayerCommon

public protocol TrackOutput {
    func setDurationUs(_ durationUs: Int64, isolation: isolated any Actor)
    func setFormat(_ format: Format, isolation: isolated any Actor) throws
    @discardableResult
    func loadSampleData(
        input: DataReader,
        length: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult
    func sampleData(data: ByteBuffer, length: Int, isolation: isolated any Actor) throws
    func sampleMetadata(time: Int64, flags: SampleFlags, size: Int, offset: Int, isolation: isolated any Actor) throws
}

public extension TrackOutput {
    func setDurationUs(_ durationUs: Int64, isolation: isolated any Actor) {}
}
