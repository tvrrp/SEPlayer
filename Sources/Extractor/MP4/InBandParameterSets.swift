//
//  InBandParameterSets.swift
//  SEPlayer
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// The H.264 parameter sets a track carries in its samples rather than in its sample entry, as `avc3` allows.
struct InBandParameterSets {
    let nalUnitLengthFieldLength: Int

    private(set) var sequenceParameterSets: [[UInt8]] = []
    private(set) var pictureParameterSets: [[UInt8]] = []

    /// Whether a track's samples carry the parameter sets: H.264 whose sample entry has none.
    static func areCarried(by format: AnyFormat) -> Bool {
        guard let codec = format.video?.codec, codec.mimeType == .videoH264 else {
            return false
        }
        let h264 = codec.h264
        return h264.sequenceParameterSets?.isEmpty != false || h264.pictureParameterSets?.isEmpty != false
    }

    /// Takes the parameter sets of `sample`. A sample that repeats only one kind, such as a picture parameter set
    /// alone, keeps the other.
    ///
    /// - Returns: Whether the parameter sets changed and both kinds are known.
    mutating func update(from sample: CMBlockBuffer) throws -> Bool {
        guard [1, 2, 4].contains(nalUnitLengthFieldLength) else { return false }

        // Most samples carry no parameter sets, and most that do repeat the ones before: bytes are copied out of
        // the sample only when they differ from the ones kept.
        let reader = BlockBufferReader(sample)
        let locations = try locateParameterSets(in: reader)
        var hasChanged = false

        if !locations.sequence.isEmpty, !isEqual(sequenceParameterSets, to: locations.sequence, in: reader) {
            sequenceParameterSets = try locations.sequence.map {
                try reader.getBytes(at: $0.lowerBound, length: $0.count)
            }
            hasChanged = true
        }
        if !locations.picture.isEmpty, !isEqual(pictureParameterSets, to: locations.picture, in: reader) {
            pictureParameterSets = try locations.picture.map {
                try reader.getBytes(at: $0.lowerBound, length: $0.count)
            }
            hasChanged = true
        }

        return hasChanged && !sequenceParameterSets.isEmpty && !pictureParameterSets.isEmpty
    }

    /// `format` with the latest parameter sets, or `nil` until the samples have carried both kinds.
    ///
    /// The record of the parameter sets takes the place of the sample entry's, which has none, as `avc1`: decoders
    /// know that type, and decode an `avc3` whose record has the parameter sets alike.
    func format(updating format: AnyFormat) throws -> AnyFormat? {
        guard let first = sequenceParameterSets.first, !pictureParameterSets.isEmpty, var video = format.video else {
            return nil
        }

        let sps = try NalUnitUtil.parseSpsNalUnit(nalData: first, nalOffset: 0, nalLimit: first.count)
        let record = AvcUtil.configurationRecord(
            sequenceParameterSets: sequenceParameterSets,
            pictureParameterSets: pictureParameterSets,
            sequenceParameterSet: sps,
            nalUnitLengthSize: nalUnitLengthFieldLength
        )
        video.size = VideoSize(
            width: sps.width,
            height: sps.height,
            pixelWidthHeightRatio: video.size?.pixelWidthHeightRatio ?? 1
        )
        try video.replaceConfigurationRecord(with: record, codecType: kCMVideoCodecType_H264, flavor: .h264)
        video.codec?.h264.hasInBandParameterSets = true
        video.codecs = video.codec?.h264.codecs() ?? video.codecs
        video.maxReorderFrames = sps.maxNumReorderFrames
        return AnyFormat(video)
    }
}

private extension InBandParameterSets {
    static let sequenceParameterSetType: UInt8 = 7
    static let pictureParameterSetType: UInt8 = 8

    /// Where the parameter sets are in `reader`, as ranges of its indices.
    func locateParameterSets(
        in reader: BlockBufferReader
    ) throws -> (sequence: [Range<Int>], picture: [Range<Int>]) {
        var sequence: [Range<Int>] = []
        var picture: [Range<Int>] = []
        var reader = reader

        while reader.readableBytes >= nalUnitLengthFieldLength {
            let length = switch nalUnitLengthFieldLength {
            case 1: try Int(reader.readInt(as: UInt8.self))
            case 2: try Int(reader.readInt(as: UInt16.self))
            default: try Int(reader.readInt(as: UInt32.self))
            }
            guard length > 0, length <= reader.readableBytes else { break }

            let range = reader.readerIndex ..< (reader.readerIndex + length)
            let header = try reader.getInt(at: reader.readerIndex, as: UInt8.self)
            switch header & 0x1F {
            case Self.sequenceParameterSetType:
                sequence.append(range)
            case Self.pictureParameterSetType:
                picture.append(range)
            default:
                break
            }

            reader.moveReaderIndex(forwardBy: length)
        }

        return (sequence, picture)
    }

    /// Whether the bytes of `reader` in `ranges` are `parameterSets`.
    func isEqual(_ parameterSets: [[UInt8]], to ranges: [Range<Int>], in reader: BlockBufferReader) -> Bool {
        guard parameterSets.count == ranges.count else { return false }

        for (parameterSet, range) in zip(parameterSets, ranges) {
            guard parameterSet.count == range.count else { return false }
            guard let slice = try? reader.getSlice(at: range.lowerBound, length: range.count) else {
                return false
            }

            // Compared in place where the bytes are contiguous, which they are but for a sample split across reads.
            let isEqualInPlace = try? slice.withUnsafeReadableBuffer { $0.elementsEqual(parameterSet) }
            let isEqual = isEqualInPlace
                ?? ((try? reader.getBytes(at: range.lowerBound, length: range.count)) == parameterSet)
            guard isEqual else { return false }
        }

        return true
    }
}
