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
    func createExtractors(url: URL?, httpHeaders: [AnyHashable : Any]) -> [Extractor]
}

public struct DefaultExtractorFactory: ExtractorsFactory {
    private let queue: Queue
    private let subtitleParserFactory: SubtitleParserFactory

    public init(queue: Queue) {
        self.queue = queue
        self.subtitleParserFactory = DefaultSubtitleParserFactory()
    }

    public func createExtractors() -> [Extractor] {
        createExtractors(url: nil, httpHeaders: [:])
    }

    public func createExtractors(url: URL?, httpHeaders: [AnyHashable : Any]) -> [Extractor] {
        [
            MP4Extractor(queue: queue, subtitleParserFactory: subtitleParserFactory),
//            FragmentedMp4Extractor(queue: queue, extractorOutput: output)
        ]
    }
}
