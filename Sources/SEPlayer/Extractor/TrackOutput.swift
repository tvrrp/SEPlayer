//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public protocol TrackOutput {
    func setFormat(_ format: Format)
    @discardableResult
    func loadSampleData(
        input: DataReader,
        length: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult
    func sampleData(data: ByteBuffer, length: Int, isolation: isolated any Actor) throws
    func sampleMetadata(time: Int64, flags: SampleFlags, size: Int, offset: Int)
}
