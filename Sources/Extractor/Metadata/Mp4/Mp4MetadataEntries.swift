//
//  Mp4MetadataEntries.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.container.MdtaMetadataEntry
//    androidx.media3.container.Mp4TimestampData
//  Copyright (C) 2019, 2023 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreLocation
import CoreMedia
import Foundation
import SEPlayerCommon

/// A metadata entry of an MP4 `meta` box of the `mdta` handler: a key and its typed value.
public struct MdtaMetadataEntry: Metadata.Entry {
    /// The key of the capture frame rate that Android cameras write.
    public static let keyAndroidCaptureFps = "com.android.capture.fps"

    public static let typeIndicatorReserved = 0
    public static let typeIndicatorString = 1
    public static let typeIndicatorFloat32 = 23
    public static let typeIndicatorInt32 = 67
    public static let typeIndicator8BitUnsignedInt = 75
    public static let typeIndicatorUnsignedInt64 = 78

    public let key: String
    public let value: Data
    public let localeIndicator: Int
    /// The type of the value, from the well-known types of the QuickTime file format.
    public let typeIndicator: Int

    public var description: String {
        let formatted: String = switch typeIndicator {
        case Self.typeIndicatorString: String(data: value, encoding: .utf8) ?? ""
        case Self.typeIndicatorFloat32 where value.count == 4: "\(Float(bitPattern: bigEndianValue(UInt32.self)))"
        case Self.typeIndicatorInt32 where value.count == 4: "\(Int32(bitPattern: bigEndianValue(UInt32.self)))"
        case Self.typeIndicator8BitUnsignedInt where value.count == 1: "\(bigEndianValue(UInt8.self))"
        case Self.typeIndicatorUnsignedInt64 where value.count == 8: "\(bigEndianValue(UInt64.self))"
        default: value.map { String(format: "%02x", $0) }.joined()
        }
        return "mdta: key=\(key), value=\(formatted)"
    }

    public init(key: String, value: Data, localeIndicator: Int, typeIndicator: Int) {
        self.key = key
        self.value = value
        self.localeIndicator = localeIndicator
        self.typeIndicator = typeIndicator
    }

    private func bigEndianValue<T: FixedWidthInteger>(_ type: T.Type) -> T {
        value.reduce(T.zero) { $0 << 8 | T($1) }
    }
}

/// The creation and modification times of an MP4 file, from its `mvhd` box.
public struct Mp4TimestampData: Metadata.Entry {
    public let creationDate: Date
    public let modificationDate: Date
    /// The units of a second that the times of the movie are counted in.
    public let timescale: CMTimeScale

    public var description: String {
        "Mp4Timestamp: creation date=\(creationDate), modification date=\(modificationDate), timescale=\(timescale)"
    }

    public init(creationDate: Date, modificationDate: Date, timescale: CMTimeScale) {
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.timescale = timescale
    }

    /// Reads an `mvhd` box, from its size field.
    init(mvhd: BlockBufferReader?) throws {
        guard var mvhd else {
            throw BoxParser.BoxParserErrors.missingBox(type: .mvhd)
        }
        mvhd.moveReaderIndex(to: MP4Box.headerSize)
        let (version, _) = try BoxParser.readFullboxExtra(reader: &mvhd)
        // Both in seconds since midnight, January 1, 1904.
        let creationTime: UInt64
        let modificationTime: UInt64
        if version == 0 {
            creationTime = try UInt64(mvhd.readInt(as: UInt32.self))
            modificationTime = try UInt64(mvhd.readInt(as: UInt32.self))
        } else {
            creationTime = try mvhd.readInt(as: UInt64.self)
            modificationTime = try mvhd.readInt(as: UInt64.self)
        }
        creationDate = Date(timeInterval: TimeInterval(creationTime), since: Self.epoch)
        modificationDate = Date(timeInterval: TimeInterval(modificationTime), since: Self.epoch)
        timescale = try CMTimeScale(truncatingIfNeeded: mvhd.readInt(as: UInt32.self))
    }

    /// Midnight, January 1, 1904 in UTC: 2 082 844 800 seconds before 1970.
    private static let epoch = Date(timeIntervalSince1970: -2_082_844_800)
}

/// The location an MP4 file was recorded at, from its `©xyz` box.
public struct Mp4LocationData: Metadata.Entry {
    public let coordinate: CLLocationCoordinate2D

    public var description: String { "xyz: latitude=\(coordinate.latitude), longitude=\(coordinate.longitude)" }

    public init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }

    public static func == (lhs: Mp4LocationData, rhs: Mp4LocationData) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
    }
}

/// The slow motion metadata of Samsung cameras, from an `smta` box.
public struct SmtaMetadataEntry: Metadata.Entry {
    /// The frame rate the video was captured at.
    public let captureFrameRate: Float
    /// The number of layers of the SVC encoding.
    public let svcTemporalLayerCount: Int

    public var description: String {
        "smta: captureFrameRate=\(captureFrameRate), svcTemporalLayerCount=\(svcTemporalLayerCount)"
    }

    public init(captureFrameRate: Float, svcTemporalLayerCount: Int) {
        self.captureFrameRate = captureFrameRate
        self.svcTemporalLayerCount = svcTemporalLayerCount
    }
}

/// A chapter of a Nero `chpl` box.
public struct ChapterEntry: Metadata.Entry {
    /// The start of the chapter, or `.invalid` if it isn't known.
    public let startTime: CMTime
    public let title: String

    public var description: String { "Chapter: start=\(startTime.seconds) s, title=\(title)" }

    public init(startTime: CMTime, title: String) {
        self.startTime = startTime
        self.title = title
    }
}
