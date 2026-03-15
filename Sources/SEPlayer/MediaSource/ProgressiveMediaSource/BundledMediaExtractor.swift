//
//  BundledMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSURLSession
import Extractor
import SEPlayerCommon

final class BundledMediaExtractor: ProgressiveMediaExtractor {
    private let syncActor: PlayerActor
    private let extractorsFactory: ExtractorsFactory

    private var extractor: Extractor?
    private var extractorInput: ExtractorInput?

    init(syncActor: PlayerActor, extractorsFactory: ExtractorsFactory) {
        self.syncActor = syncActor
        self.extractorsFactory = extractorsFactory
    }

    func prepare(
        dataReader: DataReader,
        url: URL,
        response: URLResponse?,
        range: NSRange,
        output: ExtractorOutput,
        isolation: isolated any Actor
    ) async throws {
        syncActor.assertIsolated()
        let extractorInput = DefaltExtractorInput(dataReader: dataReader, syncActor: syncActor, range: range)
        self.extractorInput = extractorInput
        guard extractor == nil else { return }
        let httpHeaders = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        let extractors = extractorsFactory.createExtractors(url: url, httpHeaders: httpHeaders)

        var sniffFailures = [SniffFailure]()
        if extractors.count == 1 {
            extractor = extractors[0]
        } else {
            for extractor in extractors {
                func postAction() { extractorInput.resetPeekPosition(isolation: isolation) }

                do {
                    if try await extractor.shiff(input: extractorInput, isolation: isolation) {
                        self.extractor = extractor
                        postAction()
                        break
                    } else {
                        sniffFailures.append(contentsOf: extractor.getSniffFailureDetails(isolation: isolation))
                    }
                } catch is EndOfFileError {
                    // Do nothing
                }

                postAction()
            }

            if extractor == nil {
                throw UnrecognizedInputFormatError(
                    message: "None of the available extractors could read the stream.",
                    url: url,
                    sniffFailures: sniffFailures
                )
            }
        }

        try extractor?.initialize(output: output, isolation: isolation)
    }

    func release() {
        Task {
            await syncActor.run { _ in
                await extractor?.release(isolation: syncActor)
                extractor = nil
                extractorInput = nil
            }
        }
    }

    func getCurrentInputPosition(isolation: isolated any Actor) -> Int? {
        syncActor.assertIsolated()
        return extractorInput?.getPosition(isolation: isolation)
    }

    func seek(position: Int, time: Int64, isolation: isolated any Actor) throws {
        syncActor.assertIsolated()
        try extractor?.seek(to: position, timeUs: time, isolation: isolation)
    }

    func read(isolation: isolated any Actor) async throws -> ExtractorReadResult {
        syncActor.assertIsolated()
        guard let extractor, let extractorInput else {
            throw ErrorBuilder.illegalState
        }

        return try await extractor.read(input: extractorInput, isolation: isolation)
    }
}
