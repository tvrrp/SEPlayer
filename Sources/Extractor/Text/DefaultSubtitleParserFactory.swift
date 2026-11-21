//
//  DefaultSubtitleParserFactory.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import SEPlayerCommon

public struct DefaultSubtitleParserFactory: SubtitleParserFactory {
    public init() {}

    public func supportsFormat(_ format: TextFormat) -> Bool {
        switch format.codec?.mimeType {
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

    public func getCueReplacementBehavior(format: TextFormat) throws -> CueReplacementBehavior {
        switch format.codec?.mimeType {
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

    public func create(format: TextFormat) throws -> SubtitleParser {
        let codec = try format.codec.checkNotNil()
        return switch codec.mimeType {
        case .applicationTX3G:
            Tx3gParser(sampleEntry: codec.tx3g.sampleEntry)
        case .textVTT:
            WebvttParser()
        case .applicationMP4VTT:
            Mp4WebvttParser()
        case .applicationCEA608,
             .applicationMP4CEA608:
            Cea608Parser(mimeType: codec.mimeType, channel: codec.cea608.channel)
        case .applicationCEA708:
            Cea708Parser(serviceNumber: codec.cea708.serviceNumber)
        case .applicationDVBSubs:
            try DvbParser(
                compositionPageID: codec.dvbSubtitle.compositionPageID.checkNotNil(),
                ancillaryPageID: codec.dvbSubtitle.ancillaryPageID.checkNotNil()
            )
        default:
            throw UnexpectedStateError()
        }
    }
}

/// A subtitle parser factory that supports no formats.
public struct UnsupportedSubtitleParserFactory: SubtitleParserFactory {
    public init() {}

    public func supportsFormat(_ format: TextFormat) -> Bool { false }

    public func getCueReplacementBehavior(format: TextFormat) throws -> CueReplacementBehavior {
        .merge
    }

    public func create(format: TextFormat) throws -> SubtitleParser {
        throw ErrorBuilder(errorDescription: "This SubtitleParserFactory doesn't support any formats.")
    }
}
