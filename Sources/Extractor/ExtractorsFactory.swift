//
//  ExtractorsFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import Foundation.NSURL
import SEPlayerCommon

public protocol ExtractorsFactory {
    func createExtractors() -> [Extractor]
    func createExtractors2() -> [Extractor2]
    func createExtractors(url: URL?, httpHeaders: [AnyHashable : Any]) -> [Extractor]
    func createExtractors2(url: URL?, httpHeaders: [AnyHashable : Any]) -> [Extractor2]
}

public extension ExtractorsFactory {
    func createExtractors() -> [Extractor] {
        createExtractors(url: nil, httpHeaders: [:])
    }
    func createExtractors2() -> [Extractor2] {
        createExtractors2(url: nil, httpHeaders: [:])
    }
}

public struct DefaultExtractorFactory: ExtractorsFactory {
    private let queue: Queue
    private let subtitleParserFactory: SubtitleParserFactory

    public init(queue: Queue) {
        self.queue = queue
        self.subtitleParserFactory = DefaultSubtitleParserFactory()
    }

    public func createExtractors(url: URL?, httpHeaders: [AnyHashable : Any]) -> [Extractor] {
        [
            MP4Extractor(queue: queue, subtitleParserFactory: subtitleParserFactory),
//            FragmentedMp4Extractor(queue: queue, extractorOutput: output)
        ]
    }

    public func createExtractors2(url: URL?, httpHeaders: [AnyHashable : Any]) -> [any Extractor2] {
        [
            MP4Extractor2(queue: queue, subtitleParserFactory: subtitleParserFactory),
        ]
    }
}
