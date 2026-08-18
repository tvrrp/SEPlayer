//
//  ExtractorOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import SEPlayerCommon

public protocol ExtractorOutput {
    func track(for id: Int, trackType: TrackType) throws -> TrackOutput
    func endTracks()
    func seekMap(seekMap: SeekMap)
}

public struct PlaceholderExtractorOutput: ExtractorOutput {
    public func track(for id: Int, trackType: TrackType) throws -> any TrackOutput {
        throw UnsupportedOperationError()
    }

    public func endTracks() {}
    public func seekMap(seekMap: SeekMap) {}
}
