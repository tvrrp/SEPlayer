//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import SEPlayerCommon

public protocol TrackOutput {
    func setDuration(_ duration: CMTime, isolation: isolated any Actor)
    func setFormat(_ format: Format, isolation: isolated any Actor) throws
    @discardableResult
    func loadSampleData(
        input: DataReader,
        length: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult
    func sampleData(data: ByteBuffer, length: Int, isolation: isolated any Actor) throws
    func sampleMetadata(time: CMSampleTimingInfo, flags: SampleFlags, size: Int, offset: Int, isolation: isolated any Actor) throws
}

public extension TrackOutput {
    func setDuration(_ duration: CMTime, isolation: isolated any Actor) {}
}
