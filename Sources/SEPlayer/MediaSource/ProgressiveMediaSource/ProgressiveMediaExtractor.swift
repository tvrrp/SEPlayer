//
//  ProgressiveMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation.NSURLSession
import Extractor
import SEPlayerCommon

protocol ProgressiveMediaExtractor {
    func prepare(
        dataReader: DataReader,
        url: URL,
        response: URLResponse?,
        range: NSRange,
        output: ExtractorOutput,
        isolation: isolated any Actor
    ) async throws
    func release()
    func getCurrentInputPosition(isolation: isolated any Actor) -> Int?
    func seek(position: Int, time: CMTime, isolation: isolated any Actor) throws
    func read(isolation: isolated any Actor) async throws -> ExtractorReadResult
}
