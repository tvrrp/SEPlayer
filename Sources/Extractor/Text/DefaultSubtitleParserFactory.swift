//
//  DefaultSubtitleParserFactory.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import SEPlayerCommon

public struct DefaultSubtitleParserFactory: SubtitleParserFactory {
    public init() {}

    public func supportsFormat(_ format: Format) -> Bool {
        switch format.sampleMimeType {
        case .applicationTX3G,
             .textVTT,
             .applicationMP4VTT,
             .applicationCEA608,
             .applicationMP4CEA608,
             .applicationCEA708,
             .applicationDVBSubs:
            true
        default:
            false
        }
    }

    public func getCueReplacementBehavior(format: Format) throws -> Format.CueReplacementBehavior {
        switch format.sampleMimeType {
        case .applicationTX3G:
            Tx3gParser.cueReplacementBehavior
        case .textVTT:
            WebvttParser.cueReplacementBehavior
        case .applicationMP4VTT:
            Mp4WebvttParser.cueReplacementBehavior
        case .applicationCEA608,
             .applicationMP4CEA608:
            Cea608Parser.cueReplacementBehavior
        case .applicationCEA708:
            Cea708Parser.cueReplacementBehavior
        case .applicationDVBSubs:
            DvbParser.cueReplacementBehavior
        default:
            throw UnexpectedStateError()
        }
    }

    public func create(format: Format) throws -> SubtitleParser {
        switch format.sampleMimeType {
        case .applicationTX3G:
            try Tx3gParser(initializationData: format.initializationData?.getInitializationData() ?? [])
        case .textVTT:
            WebvttParser()
        case .applicationMP4VTT:
            Mp4WebvttParser()
        case let .some(mimeType) where mimeType == .applicationCEA608 || mimeType == .applicationMP4CEA608:
            Cea608Parser(mimeType: mimeType, accessibilityChannel: format.accessibilityChannel)
        case .applicationCEA708:
            Cea708Parser(accessibilityChannel: format.accessibilityChannel)
        case .applicationDVBSubs:
            try DvbParser(initializationData: format.initializationData?.getInitializationData() ?? [])
        default:
            throw UnexpectedStateError()
        }
    }
}

/// A subtitle parser factory that supports no formats.
public struct UnsupportedSubtitleParserFactory: SubtitleParserFactory {
    public init() {}

    public func supportsFormat(_ format: Format) -> Bool { false }

    public func getCueReplacementBehavior(format: Format) throws -> Format.CueReplacementBehavior {
        .merge
    }

    public func create(format: Format) throws -> SubtitleParser {
        throw ErrorBuilder(errorDescription: "This SubtitleParserFactory doesn't support any formats.")
    }
}
