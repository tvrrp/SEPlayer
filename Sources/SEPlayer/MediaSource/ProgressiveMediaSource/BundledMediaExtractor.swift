//
//  BundledMediaExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.BundledExtractorsAdapter
//  Copyright (C) 2020 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Extractor
import Foundation.NSURLSession
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
        response: HTTPURLResponse?,
        position: Int,
        length: Int?,
        output: ExtractorOutput,
        _ isolation: isolated any Actor
    ) async throws {
        syncActor.assertIsolated()
        let extractorInput = DefaultExtractorInput(
            queue: syncActor.executor.queue,
            dataReader: dataReader,
            position: position,
            length: length
        )
        self.extractorInput = extractorInput
        guard extractor == nil else {
            return
        }

        let httpHeaders = response?.allHeaderFields ?? [:]
        let extractors = try extractorsFactory.createExtractors(url: url, httpHeaders: httpHeaders)

        var sniffFailures = [SniffFailure]()
        if extractors.count == 1 {
            extractor = extractors[0]
        } else {
            for extractor in extractors {
//                func postAction() {
//                    extractorInput = DefaultExtractorInput(
//                        queue: syncActor.executor.queue,
//                        dataReader: dataReader,
//                        position: position,
//                        length: length
//                    )
//                }

                defer { extractorInput.resetPeekPosition(isolation) }
                do {
                    if try await extractor.sniff(input: extractorInput, isolation) {
                        SELogger.info(.sniffing, "\(url.lastPathComponent) is read by \(type(of: extractor))")
                        self.extractor = extractor
//                        postAction()
                        break
                    } else {
                        sniffFailures.append(contentsOf: extractor.getSniffFailureDetails(isolation))
                    }
                } catch is EndOfFileError {
                    // Do nothing
                }
            }

            if extractor == nil {
                SELogger.error(.sniffing, "No extractor reads \(url.lastPathComponent): \(sniffFailures)")
                throw UnrecognizedInputFormatError(
                    message: "None of the available extractors could read the stream.",
                    url: url,
                    sniffFailures: sniffFailures
                )
            }
        }

        self.extractorInput = extractorInput
        try await extractor?.initialize(output: output, isolation)
    }

    func release() {
        Task {
            await syncActor.run { _ in
                await extractor?.release(syncActor)
                extractor = nil
                extractorInput = nil
            }
        }
    }

    func getCurrentInputPosition(_ isolation: isolated any Actor) -> Int? {
        syncActor.assertIsolated()
        return extractorInput?.getPosition(isolation)
    }

    func seek(position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        syncActor.assertIsolated()
        try extractor?.seek(to: position, time: time, isolation)
    }

    func read(_ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        syncActor.assertIsolated()
        guard let extractor, let extractorInput else {
            throw ErrorBuilder.illegalState()
        }

        return try await extractor.read(input: extractorInput, isolation)
    }
}
