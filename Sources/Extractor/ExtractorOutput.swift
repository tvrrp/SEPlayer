//
//  ExtractorOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ExtractorOutput
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
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
