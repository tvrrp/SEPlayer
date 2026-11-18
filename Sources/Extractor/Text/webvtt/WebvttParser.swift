//
//  WebvttParser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.10.2026.
//

import Foundation
import SEPlayerCommon

/// A ``SubtitleParser`` for WebVTT.
///
/// A file is a header, then STYLE blocks, comments and cues. The cues are emitted as events: between two times where
/// cues start or end, all the cues that show.
public final class WebvttParser: SubtitleParser {
    public static let cueReplacementBehavior = Format.CueReplacementBehavior.merge

    private let cssParser = WebvttCssParser()

    public init() {}

    public func getCueReplacementBehavior() -> Format.CueReplacementBehavior {
        WebvttParser.cueReplacementBehavior
    }

    public func parse(
        data: BlockBufferReader,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws {
        var reader = try WebvttLineReader(data: data.getData(at: data.readerIndex, length: data.readableBytes))
        try WebvttParserUtil.validateWebvttHeaderLine(&reader)
        // The rest of the header.
        while let line = reader.readLine(), !line.isEmpty {}

        var definedStyles: [WebvttCssStyle] = []
        var cueInfos: [WebvttCueInfo] = []
        while true {
            switch nextEvent(&reader) {
            case .endOfFile:
                let subtitle = WebvttSubtitle(cueInfos: cueInfos)
                try subtitle.toCuesWithTiming(outputOptions: outputOptions, output: output)
                return
            case .comment:
                skipComment(&reader)
            case .styleBlock:
                guard cueInfos.isEmpty else {
                    throw ParserError.createForMalformedDataOfUnknownType(message: "A style block was found after the first cue.")
                }
                // The STYLE line.
                _ = reader.readLine()
                definedStyles.append(contentsOf: cssParser.parseBlock(&reader))
            case .cue:
                if let cueInfo = WebvttCueParser.parseCue(&reader, styles: definedStyles) {
                    cueInfos.append(cueInfo)
                }
            }
        }
    }

    /// What the next block is, without reading it. Empty lines between blocks are skipped.
    private func nextEvent(_ reader: inout WebvttLineReader) -> Event {
        while let line = reader.peekLine() {
            if line.isEmpty {
                _ = reader.readLine()
            } else if line == .styleStart {
                return .styleBlock
            } else if line.hasPrefix(.commentStart) {
                return .comment
            } else {
                return .cue
            }
        }
        return .endOfFile
    }

    private func skipComment(_ reader: inout WebvttLineReader) {
        while let line = reader.readLine(), !line.isEmpty {}
    }
}

private extension WebvttParser {
    enum Event {
        case endOfFile
        case comment
        case styleBlock
        case cue
    }
}

private extension String {
    static let styleStart = "STYLE"
    static let commentStart = "NOTE"
}
