//
//  ProgressiveMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.ProgressiveMediaExtractor
//  Copyright (C) 2020 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Extractor
import Foundation.NSURLSession
import SEPlayerCommon

protocol ProgressiveMediaExtractor {
    func prepare(
        dataReader: DataReader,
        url: URL,
        response: HTTPURLResponse?,
        position: Int,
        length: Int?,
        output: ExtractorOutput,
        _ isolation: isolated any Actor
    ) async throws
    func release()
    func getCurrentInputPosition(_ isolation: isolated any Actor) -> Int?
    func seek(position: Int, time: CMTime, _ isolation: isolated any Actor) throws
    func read(_ isolation: isolated any Actor) async throws -> ExtractorReadResult
}
