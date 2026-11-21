//
//  BoxParser+Metadata.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreLocation
import CoreMedia
import Foundation
import SEPlayerCommon

/// Reads the metadata of MP4 files: the `udta` box with its iTunes tags (`meta`/`ilst`), the `mdta` tags of a
/// `meta` box, and the times of the `mvhd` box.
extension BoxParser {
    /// The metadata of a `udta` box: iTunes tags, Samsung slow motion data, the location and Nero chapters.
    ///
    /// - Parameter ignoreArtwork: Whether to leave out cover art.
    func parseUdta(udtaBox: LeafBox, ignoreArtwork: Bool) throws -> Metadata {
        var udta = udtaBox.data
        udta.moveReaderIndex(to: MP4Box.headerSize)
        var metadata = Metadata()
        while var box = try udta.readBox() {
            switch box.type {
            case MP4Box.BoxType.meta.rawValue:
                let tags = MetadataUtil.parseUdtaMeta(&box.payload, ignoreArtwork: ignoreArtwork)
                metadata = metadata.appending(tags)
            case MP4Box.BoxType.smta.rawValue:
                metadata = metadata.appending(MetadataUtil.parseSmta(&box.payload))
            case MP4Box.BoxType.xyz.rawValue:
                metadata = metadata.appending(MetadataUtil.parseXyz(&box.payload))
            case MetadataUtil.Tag.chapters:
                metadata = metadata.appending(MetadataUtil.parseChpl(&box.payload))
            default:
                break
            }
        }
        return metadata
    }

    /// The `mdta` tags of a `meta` box: keys in a `keys` box, values in an `ilst` box.
    func parseMdtaFromMeta(meta: ContainerBox) -> Metadata? {
        guard let hdlr = meta.getLeafBoxOfType(type: .hdlr),
              let keys = meta.getLeafBoxOfType(type: .keys),
              let ilst = meta.getLeafBoxOfType(type: .ilst) else {
            return nil
        }

        do {
            // The handler type comes after the header of the box, the version and flags, and four empty bytes.
            let handlerType = try hdlr.data.getInt(at: MP4Box.fullHeaderSize + 4, as: UInt32.self)
            guard handlerType == MetadataUtil.Tag.mdtaHandler else { return nil }

            let keyNames = try MetadataUtil.parseKeys(keys.data)
            var ilstData = ilst.data
            ilstData.moveReaderIndex(to: MP4Box.headerSize)
            var entries = [any Metadata.Entry]()
            // The type of each box is the number of its key, from 1.
            while var box = try ilstData.readBox() {
                let keyIndex = Int(Int32(bitPattern: box.type)) - 1
                guard keyNames.indices.contains(keyIndex) else {
                    SELogger.warning(.metadata, "Skipped metadata with unknown key index: \(keyIndex)")
                    continue
                }
                if let entry = MetadataUtil.parseMdtaEntry(&box.payload, key: keyNames[keyIndex]) {
                    entries.append(entry)
                }
            }
            return entries.isEmpty ? nil : Metadata(entries: entries)
        } catch {
            SELogger.warning(.metadata, "Failed to read mdta metadata: \(error)")
            return nil
        }
    }

    /// The creation and modification times of an `mvhd` box.
    func parseMvhd(mvhd: LeafBox) throws -> Metadata {
        try Metadata(Mp4TimestampData(mvhd: mvhd.data))
    }
}

/// Reads the tags of MP4 `ilst` boxes and puts metadata in track formats.
enum MetadataUtil {
    /// The metadata of a track: the `mdta` tags (the capture frame rate only for video), then the others.
    static func formatMetadata(
        trackType: TrackType,
        mdtaMetadata: Metadata?,
        existing: Metadata?,
        additional: [Metadata?]
    ) -> Metadata? {
        var metadata = existing ?? Metadata()
        if let mdtaMetadata {
            let entries = mdtaMetadata.entries.compactMap { $0 as? MdtaMetadataEntry }.filter {
                $0.key != MdtaMetadataEntry.keyAndroidCaptureFps || trackType == .video
            }
            metadata = metadata.appending(entries)
        }
        for other in additional {
            metadata = metadata.appending(other)
        }
        return metadata.isEmpty ? existing : metadata
    }

    /// Sets the metadata of a track on its format.
    static func setFormatMetadata(
        mdtaMetadata: Metadata?,
        format: inout AnyFormat,
        additional: Metadata?...
    ) {
        let metadata = formatMetadata(
            trackType: format.trackType,
            mdtaMetadata: mdtaMetadata,
            existing: format.metadata,
            additional: additional
        )
        if let metadata {
            format.metadata = metadata
        }
    }

    /// Sets the encoder delay and padding of an audio track on its format.
    static func setFormatGaplessInfo(gaplessInfoHolder: GaplessInfoHolder, format: inout AnyFormat) {
        guard gaplessInfoHolder.hasGaplessInfo else { return }
        format.audio?.encoderDelay = gaplessInfoHolder.encoderDelay ?? 0
        format.audio?.encoderPadding = gaplessInfoHolder.encoderPadding ?? 0
    }
}

// MARK: - Boxes of udta and meta

extension MetadataUtil {
    /// The tags of the `ilst` box in a `meta` box of a `udta` box.
    static func parseUdtaMeta(_ meta: inout BlockBufferReader, ignoreArtwork: Bool) -> Metadata? {
        do {
            try skipVersionAndFlagsOfMetaBox(&meta)
            while var box = try meta.readBox() {
                guard box.type == MP4Box.BoxType.ilst.rawValue else { continue }
                return try parseIlst(&box.payload, ignoreArtwork: ignoreArtwork)
            }
        } catch {
            SELogger.warning(.metadata, "Failed to read udta metadata: \(error)")
        }
        return nil
    }

    /// The slow motion data of an `smta` box.
    static func parseSmta(_ smta: inout BlockBufferReader) -> Metadata? {
        do {
            try smta.skip(4) // Version and flags.
            while var box = try smta.readBox() {
                guard box.type == MP4Box.BoxType.saut.rawValue else { continue }
                try box.payload.skip(4) // Author.
                var recordingMode: UInt8?
                var svcTemporalLayerCount = 0
                for _ in 0 ..< 2 {
                    let key = try box.payload.readInt(as: UInt8.self)
                    let value = try box.payload.readInt(as: UInt8.self)
                    if key == 0x00 {
                        recordingMode = value
                    } else if key == 0x01 {
                        svcTemporalLayerCount = Int(value)
                    }
                }
                guard let captureFrameRate = try captureFrameRate(recordingMode: recordingMode, &smta) else {
                    return nil
                }
                return Metadata(SmtaMetadataEntry(
                    captureFrameRate: Float(captureFrameRate),
                    svcTemporalLayerCount: svcTemporalLayerCount
                ))
            }
        } catch {
            SELogger.warning(.metadata, "Failed to read smta metadata: \(error)")
        }
        return nil
    }

    /// The location of a `©xyz` box, such as `+37.3349-122.0090/`.
    static func parseXyz(_ xyz: inout BlockBufferReader) -> Metadata? {
        guard let length = try? Int(xyz.readInt(as: UInt16.self)), (try? xyz.skip(2)) != nil, // The language code.
              let location = try? xyz.readString(length: length) else {
            return nil
        }
        guard let latitudeEnd = location.lastIndex(where: { $0 == "+" || $0 == "-" }),
              let latitude = CLLocationDegrees(location[..<latitudeEnd]),
              let longitude = CLLocationDegrees(location[latitudeEnd...].dropLast()) else {
            return nil
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return Metadata(Mp4LocationData(coordinate: coordinate))
    }

    /// The chapters of a Nero `chpl` box.
    static func parseChpl(_ chpl: inout BlockBufferReader) -> Metadata? {
        do {
            try chpl.skip(5) // Version, flags and a reserved byte.
            let chapterCount = try Int(chpl.readInt(as: Int32.self))
            var chapters = [any Metadata.Entry]()
            for _ in 0 ..< max(chapterCount, 0) {
                // The start time is in units of 100 nanoseconds.
                let startTicks = try chpl.readInt(as: Int64.self)
                let startTime = startTicks >= 0 ? CMTime(value: startTicks, timescale: 10_000_000) : .invalid
                let titleLength = try Int(chpl.readInt(as: UInt8.self))
                try chapters.append(ChapterEntry(startTime: startTime, title: chpl.readString(length: titleLength)))
            }
            return chapters.isEmpty ? nil : Metadata(entries: chapters)
        } catch {
            return nil
        }
    }

    /// The names of the keys of a `keys` box, in the order `ilst` boxes number them.
    static func parseKeys(_ keys: BlockBufferReader) throws -> [String] {
        var keys = keys
        keys.moveReaderIndex(to: MP4Box.fullHeaderSize)
        let entryCount = try Int(keys.readInt(as: Int32.self))
        return try (0 ..< max(entryCount, 0)).map { _ in
            // The type of the box is the namespace of the key.
            guard var box = try keys.readBox() else {
                throw ParserError.createForMalformedContainer(message: "The keys box ends before its last key")
            }
            return try box.payload.readString(length: box.payload.readableBytes)
        }
    }

    /// The value of an `mdta` key, from the boxes of its `ilst` entry.
    static func parseMdtaEntry(_ entry: inout BlockBufferReader, key: String) -> MdtaMetadataEntry? {
        do {
            while var box = try entry.readBox() {
                guard box.type == MP4Box.BoxType.data.rawValue else { continue }
                let typeIndicator = try Int(box.payload.readInt(as: Int32.self))
                let localeIndicator = try Int(box.payload.readInt(as: Int32.self))
                return try MdtaMetadataEntry(
                    key: key,
                    value: box.payload.readRemainingData(),
                    localeIndicator: localeIndicator,
                    typeIndicator: typeIndicator
                )
            }
        } catch {
            SELogger.warning(.metadata, "Failed to parse metadata entry with key: \(key)")
        }
        return nil
    }
}

// MARK: - iTunes tags

private extension MetadataUtil {
    static func parseIlst(_ ilst: inout BlockBufferReader, ignoreArtwork: Bool) throws -> Metadata? {
        var entries = [any Metadata.Entry]()
        while var box = try ilst.readBox() {
            guard box.payload.readableBytes >= MP4Box.headerSize else {
                SELogger.warning(.metadata, "Skipped empty metadata entry: \(box.type.fourCharacterCode)")
                continue
            }
            if let entry = try parseIlstEntry(type: box.type, &box.payload, ignoreArtwork: ignoreArtwork) {
                entries.append(entry)
            }
        }
        return entries.isEmpty ? nil : Metadata(entries: entries)
    }

    /// The ID3 frame that says the same as an iTunes tag, from the boxes of the tag.
    static func parseIlstEntry(
        type: UInt32,
        _ entry: inout BlockBufferReader,
        ignoreArtwork: Bool
    ) throws -> (any Metadata.Entry)? {
        // The first byte of the tags of text is `©`, which some files write as the last byte of U+FFFD.
        let firstByte = type >> 24
        let isShortTag = firstByte == Tag.copyrightSign || firstByte == Tag.replacementCharacter

        if isShortTag, let frameId = Tag.textFrameIds[type & 0x00FF_FFFF] {
            return try parseTextAttribute(type: type, id: frameId, &entry)
        }
        if !isShortTag, let frameId = Tag.fullTextFrameIds[type] {
            return try parseTextAttribute(type: type, id: frameId, &entry)
        }

        switch isShortTag ? type & 0x00FF_FFFF : type {
        case Tag.comment where isShortTag:
            return try parseCommentAttribute(type: type, &entry)
        case Tag.movementIndex where isShortTag:
            return try parseIntegerAttribute(type: type, &entry).map { textFrame(id: "MVIN", $0) }
        case Tag.genre:
            return try parseStandardGenreAttribute(&entry)
        case Tag.diskNumber:
            return try parseIndexAndCountAttribute(type: type, id: "TPOS", &entry)
        case Tag.trackNumber:
            return try parseIndexAndCountAttribute(type: type, id: "TRCK", &entry)
        case Tag.tempo:
            return try parseIntegerAttribute(type: type, &entry).map { textFrame(id: "TBPM", $0) }
        case Tag.compilation:
            return try parseIntegerAttribute(type: type, &entry).map { textFrame(id: "TCMP", min($0, 1)) }
        case Tag.coverArt:
            return ignoreArtwork ? nil : try parseCoverArt(&entry)
        case Tag.rating:
            return try parseIntegerAttribute(type: type, &entry).map { commentFrame(description: "ITUNESADVISORY", $0) }
        case Tag.gaplessAlbum:
            return try parseIntegerAttribute(type: type, &entry).map {
                commentFrame(description: "ITUNESGAPLESS", min($0, 1))
            }
        case Tag.custom:
            return try parseCustomAttribute(&entry)
        default:
            SELogger.verbose(.metadata, "Skipped unknown metadata entry: \(type.fourCharacterCode)")
            return nil
        }
    }

    static func parseTextAttribute(
        type: UInt32,
        id: String,
        _ entry: inout BlockBufferReader
    ) throws -> TextInformationFrame? {
        guard var data = try entry.readDataBox() else {
            SELogger.warning(.metadata, "Failed to parse text attribute: \(type.fourCharacterCode)")
            return nil
        }
        return try TextInformationFrame(id: id, description: nil, values: [data.value.readTerminatedString()])
    }

    static func parseCommentAttribute(type: UInt32, _ entry: inout BlockBufferReader) throws -> CommentFrame? {
        guard var data = try entry.readDataBox() else {
            SELogger.warning(.metadata, "Failed to parse comment attribute: \(type.fourCharacterCode)")
            return nil
        }
        let value = try data.value.readTerminatedString()
        return CommentFrame(language: undeterminedLanguage, description: value, text: value)
    }

    static func textFrame(id: String, _ value: Int) -> TextInformationFrame {
        TextInformationFrame(id: id, description: nil, values: [String(value)])
    }

    static func commentFrame(description: String, _ value: Int) -> CommentFrame {
        CommentFrame(language: undeterminedLanguage, description: description, text: String(value))
    }

    /// The integer of one to four bytes of a tag, or `nil` if the tag has none.
    static func parseIntegerAttribute(type: UInt32, _ entry: inout BlockBufferReader) throws -> Int? {
        guard var data = try entry.readDataBox() else {
            SELogger.warning(.metadata, "Failed to parse integer attribute: \(type.fourCharacterCode)")
            return nil
        }
        switch data.value.readableBytes {
        case 1:
            return try Int(data.value.readInt(as: UInt8.self))
        case 2:
            return try Int(data.value.readInt(as: UInt16.self))
        case 3:
            return try data.value.readUInt24()
        case 4:
            // Four bytes hold a signed integer; negative ones aren't values of tags.
            let value = try data.value.readInt(as: Int32.self)
            return value >= 0 ? Int(value) : nil
        default:
            return nil
        }
    }

    static func parseIndexAndCountAttribute(
        type: UInt32,
        id: String,
        _ entry: inout BlockBufferReader
    ) throws -> TextInformationFrame? {
        guard var data = try entry.readDataBox(), data.value.readableBytes >= 6 else {
            SELogger.warning(.metadata, "Failed to parse index/count attribute: \(type.fourCharacterCode)")
            return nil
        }
        try data.value.skip(2) // Empty.
        let index = try data.value.readInt(as: UInt16.self)
        let count = try data.value.readInt(as: UInt16.self)
        guard index > 0 else {
            SELogger.warning(.metadata, "Failed to parse index/count attribute: \(type.fourCharacterCode)")
            return nil
        }
        let value = count > 0 ? "\(index)/\(count)" : "\(index)"
        return TextInformationFrame(id: id, description: nil, values: [value])
    }

    static func parseStandardGenreAttribute(_ entry: inout BlockBufferReader) throws -> TextInformationFrame? {
        guard let genreCode = try parseIntegerAttribute(type: Tag.genre, &entry),
              let genre = Id3Util.resolveV1Genre(genreCode - 1) else {
            SELogger.warning(.metadata, "Failed to parse standard genre code")
            return nil
        }
        return TextInformationFrame(id: "TCON", description: nil, values: [genre])
    }

    static func parseCoverArt(_ entry: inout BlockBufferReader) throws -> ApicFrame? {
        guard var data = try entry.readDataBox() else {
            SELogger.warning(.metadata, "Failed to parse cover art attribute")
            return nil
        }
        let mimeType: String
        switch data.typeIndicator {
        case 13: mimeType = "image/jpeg"
        case 14: mimeType = "image/png"
        default:
            SELogger.warning(.metadata, "Unrecognized cover art type: \(data.typeIndicator)")
            return nil
        }
        return try ApicFrame(
            mimeType: mimeType,
            description: nil,
            pictureType: pictureTypeFrontCover,
            pictureData: data.value.readRemainingData()
        )
    }

    /// A `----` tag: a `mean` (domain), a `name` and a `data` box.
    static func parseCustomAttribute(_ entry: inout BlockBufferReader) throws -> InternalFrame? {
        var domain: String?
        var name: String?
        var value: String?
        while var box = try entry.readBox() {
            try box.payload.skip(4) // Version and flags.
            switch box.type {
            case MP4Box.BoxType.mean.rawValue:
                domain = try box.payload.readTerminatedString()
            case MP4Box.BoxType.name.rawValue:
                name = try box.payload.readTerminatedString()
            case MP4Box.BoxType.data.rawValue:
                try box.payload.skip(4) // Empty.
                value = try box.payload.readTerminatedString()
            default:
                break
            }
        }
        guard let domain, let name, let value else { return nil }
        return InternalFrame(domain: domain, description: name, text: value)
    }

    /// The frame rate a slow motion video was captured at: of its recording mode, or of the `srfr` box that follows
    /// in `smta`.
    static func captureFrameRate(recordingMode: UInt8?, _ smta: inout BlockBufferReader) throws -> Int? {
        switch recordingMode {
        case 12: return 240 // CAMCORDER_SLOW_MOTION_V2
        case 13: return 120 // CAMCORDER_SLOW_MOTION_V2_120
        case 21: break // CAMCORDER_SLOW_MOTION_V2_HEVC
        default: return nil
        }
        guard var box = try smta.readBox(), box.type == MP4Box.BoxType.srfr.rawValue else { return nil }
        // A 16.16 fixed point number.
        return try Int(box.payload.readInt(as: UInt32.self) >> 16)
    }

    /// Skips the version and flags of a `meta` box, which ISO files have and QuickTime files don't.
    static func skipVersionAndFlagsOfMetaBox(_ meta: inout BlockBufferReader) throws {
        // The next 8 bytes are either the version, flags and the size of the next box (ISO), or the size and type of
        // the hdlr box (QuickTime).
        guard meta.readableBytes >= MP4Box.headerSize else { return }
        let isQuickTime = try meta.getInt(at: meta.readerIndex + 4, as: UInt32.self) == MP4Box.BoxType.hdlr.rawValue
        if !isQuickTime {
            try meta.skip(4)
        }
    }
}

// MARK: - Tags

private extension MetadataUtil {
    static let pictureTypeFrontCover = 3
    static let undeterminedLanguage = "und"
}

extension MetadataUtil {
    enum Tag {
        static let chapters: UInt32 = 0x6368_706C // chpl
        static let mdtaHandler: UInt32 = 0x6D64_7461 // mdta

        static let copyrightSign: UInt32 = 0xA9
        /// The last byte of U+FFFD in UTF-8.
        static let replacementCharacter: UInt32 = 0xFD

        static let comment: UInt32 = 0x0063_6D74 // ©cmt
        static let movementIndex: UInt32 = 0x006D_7669 // ©mvi
        static let coverArt: UInt32 = 0x636F_7672 // covr
        static let genre: UInt32 = 0x676E_7265 // gnre
        static let diskNumber: UInt32 = 0x6469_736B // disk
        static let trackNumber: UInt32 = 0x7472_6B6E // trkn
        static let tempo: UInt32 = 0x746D_706F // tmpo
        static let compilation: UInt32 = 0x6370_696C // cpil
        static let rating: UInt32 = 0x7274_6E67 // rtng
        static let gaplessAlbum: UInt32 = 0x7067_6170 // pgap
        static let custom: UInt32 = 0x2D2D_2D2D // ----

        /// The ID3 frames of the tags of text that start with `©`, by their last three characters.
        static let textFrameIds: [UInt32: String] = [
            0x006E_616D: "TIT2", // ©nam
            0x0074_726B: "TIT2", // ©trk
            0x0063_6F6D: "TCOM", // ©com
            0x0077_7274: "TCOM", // ©wrt
            0x0064_6179: "TDRC", // ©day
            0x0041_5254: "TPE1", // ©ART
            0x0074_6F6F: "TSSE", // ©too
            0x0061_6C62: "TALB", // ©alb
            0x006C_7972: "USLT", // ©lyr
            0x0067_656E: "TCON", // ©gen
            0x0067_7270: "TIT1", // ©grp
            0x006D_766E: "MVNM", // ©mvn
        ]

        /// The ID3 frames of the other tags of text.
        static let fullTextFrameIds: [UInt32: String] = [
            0x6141_5254: "TPE2", // aART
            0x736F_6E6D: "TSOT", // sonm
            0x736F_616C: "TSOA", // soal
            0x736F_6172: "TSOP", // soar
            0x736F_6161: "TSO2", // soaa
            0x736F_636F: "TSOC", // soco
            0x736F_736E: "TVSHOWSORT", // sosn
            0x7476_7368: "TVSHOW", // tvsh
        ]
    }
}

// MARK: - Reading boxes

private struct BoxContent {
    let type: UInt32
    /// What follows the size and the type of the box.
    var payload: BlockBufferReader
}

/// The content of a `data` box, which holds the value of a tag.
private struct DataBoxContent {
    /// How the value is written: 13 for a JPEG picture, say.
    let typeIndicator: Int
    var value: BlockBufferReader
}

private extension BlockBufferReader {
    /// Reads the next box, or `nil` at the end of the data or at a box smaller than its own header.
    mutating func readBox() throws -> BoxContent? {
        guard readableBytes >= MP4Box.headerSize else { return nil }
        let size = try Int(readInt(as: Int32.self))
        let type = try readInt(as: UInt32.self)
        guard size >= MP4Box.headerSize else {
            moveReaderIndex(forwardBy: readableBytes)
            return nil
        }
        let payloadLength = min(size - MP4Box.headerSize, readableBytes)
        return try BoxContent(type: type, payload: readSlice(length: payloadLength))
    }

    /// Reads the next box if it is a `data` box: its version, the type of its value, four empty bytes and the value.
    mutating func readDataBox() throws -> DataBoxContent? {
        guard var box = try readBox(), box.type == MP4Box.BoxType.data.rawValue else { return nil }
        let typeIndicator = try Int(box.payload.readInt(as: UInt32.self) & 0x00FF_FFFF)
        try box.payload.skip(4)
        return DataBoxContent(typeIndicator: typeIndicator, value: box.payload)
    }
}
