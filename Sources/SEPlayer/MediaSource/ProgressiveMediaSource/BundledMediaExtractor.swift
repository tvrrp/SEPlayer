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
        let extractorInput = DefaltExtractorInput(dataReader: dataReader, queue: queue, range: range)
        self.extractorInput = extractorInput
        guard extractor == nil else { return }
        let httpHeaders = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        let extractors = extractorsFactory.createExtractors(output: output, url: url, httpHeaders: httpHeaders)

        var sniffFailures = [SniffFailure]()
        if extractors.count == 1 {
            extractor = extractors[0]
        } else {
            for extractor in extractors {
                func postAction() { extractorInput.resetPeekPosition() }

                do {
                    try extractor.shiff(input: extractorInput)
                    self.extractor = extractor
                    postAction()
                    break
                } catch {
                    if let error = error as? SniffFailure {
                        sniffFailures.append(error)
                    }
                }

                postAction()
            }

            if extractor == nil {
                fatalError("\(sniffFailures)")
                // TODO: throw error
            }
        }
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
