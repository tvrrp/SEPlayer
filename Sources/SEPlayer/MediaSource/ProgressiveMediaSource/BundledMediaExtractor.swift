//
//  BundledMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation.NSURLSession
import Extractor
import SEPlayerCommon

final class BundledMediaExtractor: ProgressiveMediaExtractor {
    private let syncActor: PlayerActor
    private let extractorsFactory: ExtractorsFactory

    private var extractor: Extractor2?
    private var extractorInput: ExtractorInput2?

    init(syncActor: PlayerActor, extractorsFactory: ExtractorsFactory) {
        self.syncActor = syncActor
        self.extractorsFactory = extractorsFactory
    }

    func prepare(
        dataReader: DataReader2,
        url: URL,
        response: HTTPURLResponse?,
        position: Int,
        lenght: Int?,
        output: ExtractorOutput2,
        isolation: isolated any Actor
    ) async throws {
        syncActor.assertIsolated()

        guard extractor == nil else {
            self.extractorInput?.setPosition(position, isolation: isolation)
            return
        }
        var extractorInput = DefaultExtractorInput2(
            queue: syncActor.executor.queue,
            dataReader: dataReader,
            position: position,
            lenght: lenght
        )

        let httpHeaders = response?.allHeaderFields ?? [:]
        let extractors = extractorsFactory.createExtractors2(url: url, httpHeaders: httpHeaders)

        var sniffFailures = [SniffFailure]()
        if extractors.count == 1 {
            extractor = extractors[0]
        } else {
            for extractor in extractors {
                func postAction() {
                    extractorInput = DefaultExtractorInput2(
                        queue: syncActor.executor.queue,
                        dataReader: dataReader,
                        position: position,
                        lenght: lenght
                    )
                }

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

        self.extractorInput = extractorInput
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

    func seek(position: Int, time: CMTime, isolation: isolated any Actor) throws {
        syncActor.assertIsolated()
        try extractor?.seek(to: position, time: time, isolation: isolation)
    }

    func read(isolation: isolated any Actor) async throws -> ExtractorReadResult {
        syncActor.assertIsolated()
        guard let extractor, let extractorInput else {
            throw ErrorBuilder.illegalState
        }

        return try await extractor.read(input: extractorInput, isolation: isolation)
    }
}
