//
//  DefaultSubtitleParserFactory.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import SEPlayerCommon

struct DefaultSubtitleParserFactory: SubtitleParserFactory {
    func supportsFormat(_ format: Format) -> Bool {
        switch format.sampleMimeType {
        case .applicationTX3G:
            return true
        default:
            return false
        }
    }

    func getCueReplacementBehavior(format: Format) throws -> Format.CueReplacementBehavior {
        switch format.sampleMimeType {
        case .applicationTX3G:
            return Tx3gParser.cueReplacementBehavior
        default:
            throw UnexpectedStateError()
        }
    }

    func create(format: Format) throws -> SubtitleParser {
        switch format.sampleMimeType {
        case .applicationTX3G:
            return try Tx3gParser(initializationData: format.getInitializationData())
        default:
            throw UnexpectedStateError()
        }
    }
}
