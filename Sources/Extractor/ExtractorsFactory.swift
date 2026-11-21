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
        // The extractors of the types the response and the url name are tried first, then the others.
        let inferred = [FileType(mimeType: Self.contentType(httpHeaders)), FileType(url: url)].compactMap { $0 }
        var fileTypes = [FileType]()
        for fileType in inferred + Self.fileTypes where !fileTypes.contains(fileType) {
            fileTypes.append(fileType)
        }
        return try fileTypes.flatMap(makeExtractors)
    }

    private func makeExtractors(_ fileType: FileType) throws -> [Extractor] {
        switch fileType {
        case .mp4:
            [
                FragmentedMp4Extractor(queue: queue, subtitleParserFactory: subtitleParserFactory),
                MP4Extractor(queue: queue, subtitleParserFactory: subtitleParserFactory),
            ]
        case .ts:
            try [TsExtractor(queue: queue, subtitleParserFactory: subtitleParserFactory)]
        case .adts:
            try [AdtsExtractor(flags: .enableConstantBitrateSeeking)]
        case .ac3:
            try [Ac3Extractor()]
        case .ac4:
            try [Ac4Extractor()]
        case .mp3:
            [Mp3Extractor(queue: queue, flags: .enableConstantBitrateSeeking)]
        case .webvtt:
            []
        }
    }
}

private extension DefaultExtractorFactory {
    /// The types of files in the order they are sniffed: those sniffed fastest and least often by mistake first.
    static let fileTypes: [FileType] = [.mp4, .ts, .adts, .ac3, .ac4, .mp3]

    /// The type the `Content-Type` header of a response names.
    static func contentType(_ httpHeaders: [AnyHashable: Any]) -> MimeTypes? {
        let header = httpHeaders.first { ($0.key as? String)?.lowercased() == "content-type" }
        let value = (header?.value as? String) ?? (header?.value as? [String])?.first
        return value.flatMap(MimeTypes.init(contentType:))
    }
}
