//
//  ExtractorsFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import Foundation.NSURL

public protocol ExtractorsFactory {
    func createExtractors(output: ExtractorOutput) -> [Extractor]
    func createExtractors(output: ExtractorOutput, url: URL?, httpHeaders: [AnyHashable : Any]) -> [Extractor]
}

public struct DefaultExtractorFactory: ExtractorsFactory {
    let queue: Queue

    public func createExtractors(output: ExtractorOutput) -> [Extractor] {
        createExtractors(output: output, url: nil, httpHeaders: [:])
    }

    public func createExtractors(output: ExtractorOutput, url: URL?, httpHeaders: [AnyHashable : Any]) -> [Extractor] {
        [
            MP4Extractor(queue: queue, extractorOutput: output),
//            FragmentedMp4Extractor(queue: queue, extractorOutput: output)
        ]
    }
}
