//
//  InBandParameterSets.swift
//  SEPlayer
//

import CoreMedia
import SEPlayerCommon

/// The H.264 parameter sets a track carries in its samples rather than in its sample entry, as `avc3` allows.
struct InBandParameterSets {
    let nalUnitLengthFieldLength: Int

    private(set) var sequenceParameterSets: [[UInt8]] = []
    private(set) var pictureParameterSets: [[UInt8]] = []

    /// Whether a track's samples carry the parameter sets: H.264 whose sample entry has none.
    static func areCarried(by format: Format) -> Bool {
        guard format.sampleMimeType == .videoH264 else { return false }
        guard let config = format.initializationData as? AvcConfig else {
            return false
        }

        return !config.hasParameterSets
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
    func format(updating format: Format) throws -> Format? {
        guard !sequenceParameterSets.isEmpty, !pictureParameterSets.isEmpty else {
            return nil
        }

        let config = try AvcConfig(
            sequenceParameterSets: sequenceParameterSets,
            pictureParameterSets: pictureParameterSets,
            nalUnitLengthFieldLength: nalUnitLengthFieldLength
        )
        // A `pasp` box gave the sample entry its ratio, and wins over the parameter sets.
        let hasRatioOfSampleEntry = format.pixelWidthHeightRatio != 1
        let pixelWidthHeightRatio = hasRatioOfSampleEntry ? format.pixelWidthHeightRatio : config.pixelWidthHeightRatio

        return format.buildUpon()
            .setInitializationData(config)
            .setCodecs(config.codecs ?? format.codecs)
            .setSize(width: config.width, height: config.height)
            .setPixelWidthHeightRatio(pixelWidthHeightRatio)
            .setMaxNumReorderSamples(config.maxNumReorderFrames)
            .build()
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
