//
//  BundledMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSURLSession

final class BundledMediaExtractor: ProgressiveMediaExtractor {
    private let queue: Queue
    private let extractorsFactory: ExtractorsFactory

    private var extractor: Extractor?
    private var extractorInput: ExtractorInput?

    init(queue: Queue, extractorsFactory: ExtractorsFactory) {
        self.queue = queue
        self.extractorsFactory = extractorsFactory
    }

    func prepare(dataReader: DataReader, url: URL, response: URLResponse?, range: NSRange, output: ExtractorOutput) throws {
        assert(queue.isCurrent())
        extractorInput = DefaltExtractorInput(dataReader: dataReader, queue: queue, range: range)
        guard extractor == nil else { return }
        let httpHeaders = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        extractor = extractorsFactory.createExtractors(output: output, url: url, httpHeaders: httpHeaders)[0]
    }

    func release() {
        queue.async { [self] in
            extractor?.release()
            extractor = nil
            extractorInput = nil
        }
    }

    func getCurrentInputPosition() -> Int? {
        assert(queue.isCurrent())
        return extractorInput?.getPosition()
    }

    func seek(position: Int, time: Int64) {
        assert(queue.isCurrent())
        extractor?.seek(to: position, timeUs: time)
    }

    func read() throws -> ExtractorReadResult {
        assert(queue.isCurrent())
        guard let extractor, let extractorInput else {
            throw ErrorBuilder.illegalState
        }

        return try extractor.read(input: extractorInput)
    }
}
