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

public protocol ExtractorOutput2 {
    func track(for id: Int, trackType: TrackType) throws -> TrackOutput2
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

public struct PlaceholderExtractorOutput2: ExtractorOutput2 {
    public func track(for id: Int, trackType: TrackType) throws -> any TrackOutput2 {
        throw UnsupportedOperationError()
    }

    public func endTracks() {}
    public func seekMap(seekMap: SeekMap) {}
}
