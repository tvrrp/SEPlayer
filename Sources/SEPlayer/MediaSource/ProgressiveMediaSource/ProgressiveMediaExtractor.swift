//
//  ProgressiveMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSURLSession

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
    func seek(position: Int, time: Int64, isolation: isolated any Actor)
    func read(isolation: isolated any Actor) async throws -> ExtractorReadResult
}
