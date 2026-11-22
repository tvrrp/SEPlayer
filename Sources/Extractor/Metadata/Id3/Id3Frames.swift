//
//  Id3Frames.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.metadata.id3.Id3Frame
//    androidx.media3.extractor.metadata.id3.TextInformationFrame
//    androidx.media3.extractor.metadata.id3.UrlLinkFrame
//    androidx.media3.extractor.metadata.id3.CommentFrame
//    androidx.media3.extractor.metadata.id3.ApicFrame
//    androidx.media3.extractor.metadata.id3.GeobFrame
//    androidx.media3.extractor.metadata.id3.PrivFrame
//    androidx.media3.extractor.metadata.id3.BinaryFrame
//    androidx.media3.extractor.metadata.id3.ChapterFrame
//    androidx.media3.extractor.metadata.id3.ChapterTocFrame
//    androidx.media3.extractor.metadata.id3.InternalFrame
//    androidx.media3.extractor.metadata.id3.MlltFrame
//  Copyright (C) 2016, 2017, 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// A frame of an ID3 tag.
public protocol Id3Frame: Metadata.Entry {
    /// The four character frame id, or three characters for ID3v2.2.
    var id: String { get }
}

/// A text information frame: `T***`, or `TXXX` with a description.
public struct TextInformationFrame: Id3Frame {
    public let id: String
    public let frameDescription: String?
    /// The values of the frame. ID3v2.4 frames may have several; there is always at least one.
    public let values: [String]

    public var value: String { values[0] }

    public init(id: String, description: String?, values: [String]) {
        self.id = id
        frameDescription = description
        self.values = values.isEmpty ? [""] : values
    }

    public func populateMediaMetadata(_ builder: MediaMetadata.Builder) {
        switch id {
        case "TT2",
             "TIT2":
            builder.setTitle(value)
        case "TP1",
             "TPE1":
            builder.setArtist(value)
        case "TP2",
             "TPE2":
            builder.setAlbumArtist(value)
        case "TAL",
             "TALB":
            builder.setAlbumTitle(value)
        case "TRK",
             "TRCK":
            if let (number, total) = Self.numberAndTotal(value) {
                builder.setTrackNumber(number).setTotalTrackCount(total)
            }
        case "TYE",
             "TYER":
            if let year = Int(value) {
                builder.setRecordingDate(year: year)
            }
        case "TDA",
             "TDAT":
            // DDMM.
            if let day = Int(value.prefix(2)), let month = Int(value.dropFirst(2).prefix(2)) {
                builder.setRecordingDate(month: month, day: day)
            }
        case "TDRC":
            if let date = Self.dateComponents(value) {
                builder.setRecordingDate(date)
            }
        case "TDRL":
            if let date = Self.dateComponents(value) {
                builder.setReleaseDate(date)
            }
        case "TCM",
             "TCOM":
            builder.setComposer(value)
        case "TP3",
             "TPE3":
            builder.setConductor(value)
        case "TXT",
             "TEXT":
            builder.setWriter(value)
        case "TCON":
            if let code = Int(value) {
                // A numeric genre that isn't a known one isn't set.
                if let genre = Id3Util.resolveV1Genre(code) {
                    builder.setGenre(genre)
                }
            } else {
                builder.setGenre(value)
            }
        case "TSST":
            builder.setDiscSubtitle(value)
        case "TPOS":
            if let (number, total) = Self.numberAndTotal(value) {
                builder.setDiscNumber(number).setTotalDiscCount(total)
            }
        default:
            break
        }
    }

    /// The number and the optional total of a `number/total` value.
    private static func numberAndTotal(_ value: String) -> (Int, Int?)? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard let number = Int(parts[0]) else { return nil }
        guard parts.count > 1 else { return (number, nil) }
        guard let total = Int(parts[1]) else { return nil }
        return (number, total)
    }

    /// The date of an ISO 8601 timestamp of reduced precision: `yyyy`, `yyyy-MM` or `yyyy-MM-dd`, with or without a
    /// time after it.
    private static func dateComponents(_ value: String) -> DateComponents? {
        let date = value.prefix { $0 != "T" }.split(separator: "-", omittingEmptySubsequences: false)
        let numbers = date.compactMap { Int($0) }
        guard (1 ... 3).contains(date.count), numbers.count == date.count else {
            return nil
        }
        return DateComponents(
            year: numbers[0],
            month: numbers.count > 1 ? numbers[1] : nil,
            day: numbers.count > 2 ? numbers[2] : nil
        )
    }
}

/// A URL link frame: `W***`, or `WXXX` with a description.
public struct UrlLinkFrame: Id3Frame {
    public let id: String
    public let frameDescription: String?
    public let url: String

    public init(id: String, description: String?, url: String) {
        self.id = id
        frameDescription = description
        self.url = url
    }
}

/// A private frame (`PRIV`): data that its owner defines.
public struct PrivFrame: Id3Frame {
    public let id = "PRIV"
    public let owner: String
    public let privateData: Data

    public var description: String { "\(id): owner=\(owner)" }

    public init(owner: String, privateData: Data) {
        self.owner = owner
        self.privateData = privateData
    }
}

/// A general encapsulated object frame (`GEOB`).
public struct GeobFrame: Id3Frame {
    public let id = "GEOB"
    public let mimeType: String
    public let filename: String
    public let objectDescription: String
    public let data: Data

    public var description: String {
        "\(id): mimeType=\(mimeType), filename=\(filename), description=\(objectDescription)"
    }

    public init(mimeType: String, filename: String, description: String, data: Data) {
        self.mimeType = mimeType
        self.filename = filename
        objectDescription = description
        self.data = data
    }
}

/// An attached picture frame (`APIC`, `PIC` in ID3v2.2).
public struct ApicFrame: Id3Frame {
    public let id = "APIC"
    public let mimeType: String
    public let pictureDescription: String?
    /// The picture type of ID3v2.4 section 4.14.
    public let pictureType: Int
    public let pictureData: Data

    public var description: String { "\(id): mimeType=\(mimeType), description=\(pictureDescription ?? "nil")" }

    public init(mimeType: String, description: String?, pictureType: Int, pictureData: Data) {
        self.mimeType = mimeType
        pictureDescription = description
        self.pictureType = pictureType
        self.pictureData = pictureData
    }

    public func populateMediaMetadata(_ builder: MediaMetadata.Builder) {
        builder.maybeSetArtworkData(pictureData, pictureType: MediaMetadata.PictureType(rawValue: pictureType))
    }
}

/// A comment frame (`COMM`).
public struct CommentFrame: Id3Frame {
    public let id = "COMM"
    public let language: String
    public let commentDescription: String
    public let text: String

    public var description: String {
        "\(id): language=\(language), description=\(commentDescription), text=\(text)"
    }

    public init(language: String, description: String, text: String) {
        self.language = language
        commentDescription = description
        self.text = text
    }
}

/// A chapter frame (`CHAP`).
public struct ChapterFrame: Id3Frame {
    public let id = "CHAP"
    public let chapterId: String
    public let startTime: CMTime
    public let endTime: CMTime
    /// The byte offset of the start of the chapter, or `nil` if it isn't given.
    public let startOffset: Int?
    /// The byte offset of the end of the chapter, or `nil` if it isn't given.
    public let endOffset: Int?
    public let subFrames: [any Id3Frame]

    public var description: String { "\(id): chapterId=\(chapterId), \(startTime.seconds)–\(endTime.seconds) s" }

    public init(
        chapterId: String,
        startTime: CMTime,
        endTime: CMTime,
        startOffset: Int?,
        endOffset: Int?,
        subFrames: [any Id3Frame]
    ) {
        self.chapterId = chapterId
        self.startTime = startTime
        self.endTime = endTime
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.subFrames = subFrames
    }

    public static func == (lhs: ChapterFrame, rhs: ChapterFrame) -> Bool {
        lhs.chapterId == rhs.chapterId
            && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime
            && lhs.startOffset == rhs.startOffset
            && lhs.endOffset == rhs.endOffset
            && lhs.subFrames.map { AnyHashable($0) } == rhs.subFrames.map { AnyHashable($0) }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(chapterId)
        hasher.combine(startTime)
        hasher.combine(endTime)
        hasher.combine(startOffset)
        hasher.combine(endOffset)
    }
}

/// A chapter table of contents frame (`CTOC`).
public struct ChapterTocFrame: Id3Frame {
    public let id = "CTOC"
    public let elementId: String
    public let isRoot: Bool
    public let isOrdered: Bool
    /// The element ids of the chapters and tables of contents this one lists.
    public let children: [String]
    public let subFrames: [any Id3Frame]

    public var description: String { "\(id): elementId=\(elementId), children=\(children)" }

    public init(elementId: String, isRoot: Bool, isOrdered: Bool, children: [String], subFrames: [any Id3Frame]) {
        self.elementId = elementId
        self.isRoot = isRoot
        self.isOrdered = isOrdered
        self.children = children
        self.subFrames = subFrames
    }

    public static func == (lhs: ChapterTocFrame, rhs: ChapterTocFrame) -> Bool {
        lhs.elementId == rhs.elementId
            && lhs.isRoot == rhs.isRoot
            && lhs.isOrdered == rhs.isOrdered
            && lhs.children == rhs.children
            && lhs.subFrames.map { AnyHashable($0) } == rhs.subFrames.map { AnyHashable($0) }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(elementId)
        hasher.combine(isRoot)
        hasher.combine(isOrdered)
        hasher.combine(children)
    }
}

/// An MPEG location lookup table frame (`MLLT`): reference points that let an MP3 stream be seeked.
public struct MlltFrame: Id3Frame {
    public let id = "MLLT"
    public let mpegFramesBetweenReference: Int
    public let bytesBetweenReference: Int
    public let millisecondsBetweenReference: Int
    public let bytesDeviations: [Int]
    public let millisecondsDeviations: [Int]

    public var description: String { "\(id): \(bytesDeviations.count) references" }

    public init(
        mpegFramesBetweenReference: Int,
        bytesBetweenReference: Int,
        millisecondsBetweenReference: Int,
        bytesDeviations: [Int],
        millisecondsDeviations: [Int]
    ) {
        self.mpegFramesBetweenReference = mpegFramesBetweenReference
        self.bytesBetweenReference = bytesBetweenReference
        self.millisecondsBetweenReference = millisecondsBetweenReference
        self.bytesDeviations = bytesDeviations
        self.millisecondsDeviations = millisecondsDeviations
    }
}

/// A frame that isn't decoded: its id and its bytes.
public struct BinaryFrame: Id3Frame {
    public let id: String
    public let data: Data

    public var description: String { "\(id): \(data.count) bytes" }

    public init(id: String, data: Data) {
        self.id = id
        self.data = data
    }
}

/// An internal frame (`----`): a key in a domain, as in the iTunes metadata of MP4 files.
public struct InternalFrame: Id3Frame {
    public let id = "----"
    public let domain: String
    public let frameDescription: String
    public let text: String

    public var description: String { "\(id): domain=\(domain), description=\(frameDescription)" }

    public init(domain: String, description: String, text: String) {
        self.domain = domain
        frameDescription = description
        self.text = text
    }
}

public extension TextInformationFrame {
    var description: String { "\(id): description=\(frameDescription ?? "nil"): values=\(values)" }
}

public extension UrlLinkFrame {
    var description: String { "\(id): url=\(url)" }
}
