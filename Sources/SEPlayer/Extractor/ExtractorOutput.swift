//
//  ExtractorOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public protocol ExtractorOutput {
    func track(for id: Int, trackType: TrackType) -> TrackOutput
    func endTracks()
    func seekMap(seekMap: SeekMap)
}
