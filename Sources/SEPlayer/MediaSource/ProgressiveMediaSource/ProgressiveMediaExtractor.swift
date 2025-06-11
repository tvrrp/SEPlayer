//
//  ProgressiveMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSURLSession

protocol ProgressiveMediaExtractor {
    func prepare(dataReader: DataReader, url: URL, response: URLResponse?, range: NSRange, output: ExtractorOutput) throws
    func release()
    func getCurrentInputPosition() -> Int?
    func seek(position: Int, time: Int64)
    func read() throws -> ExtractorReadResult
}
