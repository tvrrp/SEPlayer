//
//  ExtractorsFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import Foundation.NSURL
import SEPlayerCommon

public protocol ExtractorsFactory {
    func createExtractors() throws -> [Extractor]
    func createExtractors(url: URL?, httpHeaders: [AnyHashable: Any]) throws -> [Extractor]
}

public extension ExtractorsFactory {
    func createExtractors() throws -> [Extractor] {
        try createExtractors(url: nil, httpHeaders: [:])
    }
}

public struct DefaultExtractorFactory: ExtractorsFactory {
    private let queue: Queue
    private let subtitleParserFactory: SubtitleParserFactory

    public init(queue: Queue) {
        self.queue = queue
        self.subtitleParserFactory = DefaultSubtitleParserFactory()
    }

    public func createExtractors(url: URL?, httpHeaders: [AnyHashable: Any]) throws -> [Extractor] {
        var extractors = [Extractor]()
        // #if ExtractorMP4
        extractors.append(MP4Extractor(queue: queue, subtitleParserFactory: subtitleParserFactory))
        // #endif
        // #if ExtractorFMP4
        extractors.append(FragmentedMp4Extractor(queue: queue, subtitleParserFactory: subtitleParserFactory))
        // #endif
        // #if ExtractorTS
        try extractors.append(TsExtractor(queue: queue, subtitleParserFactory: subtitleParserFactory))
        // #endif
        return extractors
    }
}
