//
//  ProgressiveMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
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
