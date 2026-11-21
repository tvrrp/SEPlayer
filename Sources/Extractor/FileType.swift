//
//  FileType.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.11.2026.
//

import Foundation
import SEPlayerCommon

/// The kinds of files that extractors read.
public enum FileType: Sendable {
    case mp4
    case webvtt
    case ts
    case adts
    case ac3
    case ac4
    case mp3

    /// The kind of file of `mimeType`, or `nil` if it doesn't tell.
    public init?(mimeType: MimeTypes?) {
        switch mimeType {
        case .videoMP4,
             .audioMP4,
             .applicationMP4: self = .mp4
        case .textVTT: self = .webvtt
        case .videoMP2T: self = .ts
        case .audioAAC: self = .adts
        case .audioAC3,
             .audioEAC3,
             .audioEAC3JOC: self = .ac3
        case .audioAC4: self = .ac4
        case .audioMPEG: self = .mp3
        default: return nil
        }
    }

    /// The kind of file the extension of the path of `url` names, or `nil` if it doesn't tell.
    public init?(url: URL?) {
        switch url?.pathExtension.lowercased() {
        case "mp4",
             "m4s",
             "m4a",
             "m4v",
             "cmfv",
             "cmfa",
             "cmft": self = .mp4
        case "vtt",
             "webvtt": self = .webvtt
        case "ts",
             "tsa",
             "tsv",
             "m2ts",
             "mts": self = .ts
        case "aac",
             "adts": self = .adts
        case "ac3",
             "ec3",
             "eac3": self = .ac3
        case "ac4": self = .ac4
        case "mp3",
             "mp2",
             "mpga": self = .mp3
        default: return nil
        }
    }
}
