//
//  BundledMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

final class BundledMediaExtractor: ProgressiveMediaExtractor {
    private let queue: Queue
    private let extractorQueue: Queue

    private var extractor: Extractor?
    private var extractorInput: ExtractorInput?

    init(queue: Queue, extractorQueue: Queue) {
        self.queue = queue
        self.extractorQueue = extractorQueue
    }

    func prepare(dataReader: DataReader, url: URL, response: URLResponse?, position: Int, lenght: Int, output: ExtractorOutput) throws {
        assert(queue.isCurrent())
        extractorInput = DefaltExtractorInput(dataReader: dataReader, queue: extractorQueue)
        guard extractor == nil else { return }
        extractor = MP4Extractor(queue: extractorQueue, extractorOutput: output)
    }

    func release() {
        
    }

    func getCurrentInputPosition() -> Int? {
        extractorQueue.sync { extractorInput?.getPosition() }
    }

    func seek(position: Int, time: CMTime) {
        extractorQueue.async { [weak self] in
            self?.extractor?.seek(to: position, time: time)
        }
    }

    func read(completion: @escaping (ExtractorReadResult) -> Void) {
        guard let extractor, let extractorInput else { fatalError() }
        extractorQueue.async { [weak self] in
            extractor.read(input: extractorInput) { result in
                self?.queue.async { completion(result) }
            }
        }
    }
}
