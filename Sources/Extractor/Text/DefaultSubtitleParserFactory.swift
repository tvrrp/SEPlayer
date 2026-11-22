//
//  DefaultSubtitleParserFactory.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.DefaultSubtitleParserFactory
//  Copyright (C) 2023 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

public struct DefaultSubtitleParserFactory: SubtitleParserFactory {
    public init() {}

    public func supportsFormat(_ format: TextFormat) -> Bool {
        switch format.codec?.mimeType {
        case .textVTT,
             .applicationMP4VTT,
             .applicationTX3G,
             .applicationDVBSubs,
             .applicationTTML,
             .applicationCEA608,
             .applicationMP4CEA608,
             .applicationCEA708:
            true
        default:
            false
        }
    }

    public func getCueReplacementBehavior(format: TextFormat) throws -> CueReplacementBehavior {
        switch format.codec?.mimeType {
        case .textVTT:
            WebvttParser.cueReplacementBehavior
        case .applicationMP4VTT:
            Mp4WebvttParser.cueReplacementBehavior
        case .applicationTX3G:
            Tx3gParser.cueReplacementBehavior
        case .applicationDVBSubs:
            DvbParser.cueReplacementBehavior
        case .applicationTTML:
            TtmlParser.cueReplacementBehavior
        case .applicationCEA608,
             .applicationMP4CEA608:
            Cea608Parser.cueReplacementBehavior
        case .applicationCEA708:
            Cea708Parser.cueReplacementBehavior
        default:
            throw UnexpectedStateError()
        }
    }

    public func create(format: TextFormat) throws -> SubtitleParser {
        let codec = try format.codec.checkNotNil()
        return switch codec.mimeType {
        case .textVTT:
            WebvttParser()
        case .applicationMP4VTT:
            Mp4WebvttParser()
        case .applicationTX3G:
            Tx3gParser(sampleEntry: codec.tx3g.sampleEntry)
        case .applicationDVBSubs:
            try DvbParser(
                compositionPageID: codec.dvbSubtitle.compositionPageID.checkNotNil(),
                ancillaryPageID: codec.dvbSubtitle.ancillaryPageID.checkNotNil()
            )
        case .applicationTTML:
            TtmlParser()
        // Closed captions: Media3 reads them outside of this factory.
        case .applicationCEA608,
             .applicationMP4CEA608:
            Cea608Parser(mimeType: codec.mimeType, channel: codec.cea608.channel)
        case .applicationCEA708:
            Cea708Parser(serviceNumber: codec.cea708.serviceNumber)
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
