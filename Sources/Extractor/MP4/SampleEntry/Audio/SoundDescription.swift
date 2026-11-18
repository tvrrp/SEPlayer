//
//  SoundDescription.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import SEPlayerCommon

/// An audio sample entry: an ISO `AudioSampleEntry`, or a QuickTime sound description of version 0, 1 or 2.
///
/// The version doesn't tell the layout alone: an ISO version 1 entry is as long as version 0, with the version
/// only marking a sample rate box; a QuickTime version 1 entry has four more fields. The boxes after the fields tell
/// which of the two an entry is.
struct SoundDescription {
    enum Layout {
        /// Version 0: 36 bytes.
        case version0
        /// ISO version 1: 36 bytes, its sample rate maybe in a `srat` box.
        case isoVersion1
        /// QuickTime version 1: 52 bytes, with the packet sizes of compressed formats.
        case quickTimeVersion1
        /// QuickTime version 2: the size of its fields tells where its boxes start.
        case version2
    }

    struct Version1Fields {
        let samplesPerPacket: UInt32
        let bytesPerPacket: UInt32
        let bytesPerFrame: UInt32
    }

    struct Version2Fields {
        let sampleRate: Double
        let channelCount: UInt32
        let bitsPerChannel: UInt32
        let formatFlags: UInt32
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
    }

    /// The whole entry, from its size field, its indices starting at 0.
    let entry: BlockBufferReader
    let rawFormat: UInt32
    let version: Int
    let layout: Layout
    let channelCount: Int
    let sampleSize: Int
    let compressionID: Int16
    /// The sample rate field, 16.16 fixed point; an integer for Dolby TrueHD in ISO files.
    let sampleRateField: UInt32
    let version1: Version1Fields?
    let version2: Version2Fields?
    /// Where the boxes after the fields start.
    let extensionsOffset: Int

    var format: MP4Box.BoxType? { MP4Box.BoxType(rawValue: rawFormat) }

    /// - Parameters:
    ///   - entry: The whole sample entry, from its size field, its indices starting at 0.
    ///   - isQuickTime: Whether the file is a QuickTime movie rather than an ISO file.
    init?(entry: BlockBufferReader, isQuickTime: Bool) {
        guard entry.readableBytes >= 36 else { return nil }
        do {
            self.entry = entry
            var reader = entry
            try reader.skip(4) // size
            rawFormat = try reader.readInt(as: UInt32.self)
            try reader.skip(8) // reserved (6), data reference index (2)
            version = try Int(reader.readInt(as: Int16.self))
            try reader.skip(6) // revision level (2), vendor (4)
            channelCount = try Int(reader.readInt(as: UInt16.self))
            sampleSize = try Int(reader.readInt(as: UInt16.self))
            compressionID = try reader.readInt(as: Int16.self)
            try reader.skip(2) // packet size
            sampleRateField = try reader.readInt(as: UInt32.self)

            switch version {
            case 0:
                layout = .version0
                extensionsOffset = 36
                version1 = nil
                version2 = nil
            case 1:
                let isISO = Self.isISOVersion1(entry)
                // An ISO version 1 entry has no place in a QuickTime movie.
                guard !(isISO && isQuickTime) else { return nil }
                layout = isISO ? .isoVersion1 : .quickTimeVersion1
                extensionsOffset = isISO ? 36 : 52
                version1 = try isISO ? nil : Version1Fields(
                    samplesPerPacket: reader.readInt(as: UInt32.self),
                    bytesPerPacket: reader.readInt(as: UInt32.self),
                    bytesPerFrame: reader.readInt(as: UInt32.self)
                )
                version2 = nil
            case 2 where isQuickTime:
                let structSize = try Int(reader.readInt(as: UInt32.self))
                guard structSize >= 72 else { return nil }
                layout = .version2
                extensionsOffset = structSize
                version1 = nil
                let sampleRate = try Double(bitPattern: reader.readInt(as: UInt64.self))
                let channelCount = try reader.readInt(as: UInt32.self)
                try reader.skip(4) // always 0x7F000000
                version2 = try Version2Fields(
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    bitsPerChannel: reader.readInt(as: UInt32.self),
                    formatFlags: reader.readInt(as: UInt32.self),
                    bytesPerPacket: reader.readInt(as: UInt32.self),
                    framesPerPacket: reader.readInt(as: UInt32.self)
                )
            default:
                return nil
            }
            guard extensionsOffset <= entry.readableBytes else { return nil }
        } catch {
            return nil
        }
    }

    /// The sample rate of the fields: 16.16 fixed point, or an integer for Dolby TrueHD in an ISO file.
    func sampleRate(isQuickTime: Bool) -> Double {
        if format == .mlpa && !isQuickTime {
            return Double(sampleRateField)
        }
        return Double(sampleRateField) / 65536
    }

    /// Whether the boxes follow QuickTime's conventions, a `wave` box with the codec's, rather than ISO's.
    var usesQuickTimeBoxes: Bool {
        layout == .quickTimeVersion1 || layout == .version2
    }

    // MARK: - ISO version 1

    /// Whether a version 1 entry has ISO's layout: its boxes start where version 0's do.
    ///
    /// Without boxes, or when only one of the two places starts well formed boxes, those tell. Otherwise a box only ISO
    /// entries have tells, or a format only ISO files carry; a QuickTime entry of a compressed format, which needs the
    /// packet fields, is never ISO.
    private static func isISOVersion1(_ entry: BlockBufferReader) -> Bool {
        guard let size = try? Int(entry.getInt(at: 0, as: UInt32.self)), size >= 36, size <= entry.readableBytes,
              let entry = try? entry.getSlice(at: 0, length: size) else {
            return false
        }
        if size == 36 { return true }

        let isWellFormedAt36 = SampleEntryBox.boxes(in: entry, from: 36).isWellFormed
        var isNotWellFormedAt52 = true
        if size > 52 {
            let isWellFormedAt52 = SampleEntryBox.boxes(in: entry, from: 52).isWellFormed
            isNotWellFormedAt52 = !isWellFormedAt52
            if isWellFormedAt36 && !isWellFormedAt52 { return true }
            if !isWellFormedAt36 && isWellFormedAt52 { return false }
        }

        let format = (try? entry.getInt(at: 4, as: UInt32.self)).flatMap(MP4Box.BoxType.init(rawValue:))
        if let format, [.fLaC, .fpcm, .ipcm].contains(format) { return true }

        guard let compressionID = try? entry.getInt(at: 28, as: UInt16.self), compressionID < 0xFFFE, isWellFormedAt36 else {
            return false
        }
        let hasISOBox = SampleEntryBox.boxes(in: entry, from: 36).boxes.contains { $0.type.map(isoVersion1Boxes.contains) == true }
        return hasISOBox || isNotWellFormedAt52 ? hasISOBox : false
    }

    /// Boxes only ISO version 1 entries have: the channel layout, the sample rate, downmix and loudness.
    private static let isoVersion1Boxes: Set<MP4Box.BoxType> = [.chnl, .srat, .dmix, .udc1, .udc2, .udi1, .udi2, .udex]
}

// MARK: - Boxes

extension SoundDescription {
    /// The boxes after the fields that describe the codec, the channels or the protection, and those kept as they
    /// are for the decoder.
    struct Boxes {
        var esds: SampleEntryBox?
        var dac3: SampleEntryBox?
        var dec3: SampleEntryBox?
        var dfLa: SampleEntryBox?
        var alac: SampleEntryBox?
        var dOps: SampleEntryBox?
        /// The AMR decoder config: a `damr` box in ISO files, a `samr` box in a QuickTime `wave` box.
        var amrConfig: BlockBufferReader?
        var pcmC: SampleEntryBox?
        var chnl: SampleEntryBox?
        var chan: SampleEntryBox?
        /// The payload of a QuickTime `wave` box: the codec's own boxes.
        var wave: BlockBufferReader?
        /// Whether a QuickTime `enda` box marks the samples little-endian.
        var isLittleEndian = false
        /// The sample rate of an ISO version 1 `srat` box.
        var sampleRate: UInt32?
        /// The protection scheme box, `sinf`.
        var sinf: SampleEntryBox?
        /// The boxes the decoder may need although nothing here describes them.
        var unknown: [SampleEntryBox] = []
    }

    /// The boxes after the fields. A QuickTime entry of version 0 has none that count.
    ///
    /// - Returns: `nil` for boxes that contradict the entry, such as a `frma` box of another format.
    func readBoxes(isQuickTime: Bool) -> Boxes? {
        var boxes = Boxes()
        guard !(version == 0 && isQuickTime) else { return boxes }

        for box in SampleEntryBox.boxes(in: entry, from: extensionsOffset).boxes {
            var isConsumed = true
            if usesQuickTimeBoxes {
                switch box.type {
                case .chan: if boxes.chan == nil { boxes.chan = box }
                case .wave:
                    if boxes.wave == nil {
                        boxes.wave = box.payload
                        guard readWaveBoxes(box.payload, into: &boxes) else {
                            return nil
                        }
                    }
                case .sinf:
                    if boxes.sinf == nil { boxes.sinf = box }
                    isConsumed = false
                case .dOps: if boxes.dOps == nil { boxes.dOps = box }
                default: isConsumed = false
                }
            } else {
                switch box.type {
                case .sinf:
                    if boxes.sinf == nil { boxes.sinf = box }
                    isConsumed = false
                case .alac: if boxes.alac == nil { boxes.alac = box }
                case .chnl:
                    if boxes.chnl == nil { boxes.chnl = box }
                    isConsumed = false
                case .dac3: if boxes.dac3 == nil { boxes.dac3 = box }
                case .damr: if boxes.amrConfig == nil { boxes.amrConfig = box.payload }
                case .dec3: if boxes.dec3 == nil { boxes.dec3 = box }
                case .dfLa: if boxes.dfLa == nil { boxes.dfLa = box }
                case .esds: if boxes.esds == nil { boxes.esds = box }
                case .srat:
                    if layout == .isoVersion1, let rate = try? box.payload.getInt(at: 4, as: UInt32.self) {
                        boxes.sampleRate = rate
                    }
                case .pcmC: if boxes.pcmC == nil { boxes.pcmC = box }
                case .dOps: if boxes.dOps == nil { boxes.dOps = box }
                default: isConsumed = false
                }
            }
            // The codec's config boxes become its magic cookie; others are kept for the decoder as they are.
            if !isConsumed, !(box.type.map(Self.boxesNeverKept.contains) ?? false) {
                boxes.unknown.append(box)
            }
        }
        return boxes
    }

    /// The boxes of a QuickTime `wave` box: the codec's config, as ISO entries have it, ended by a box of size zero.
    private func readWaveBoxes(_ payload: BlockBufferReader, into boxes: inout Boxes) -> Bool {
        for box in SampleEntryBox.boxes(in: payload, from: 0).boxes {
            switch box.type {
            case .alac: if boxes.alac == nil { boxes.alac = box }
            case .dac3: if boxes.dac3 == nil { boxes.dac3 = box }
            case .dec3: if boxes.dec3 == nil { boxes.dec3 = box }
            case .dfLa: if boxes.dfLa == nil { boxes.dfLa = box }
            case .enda:
                if let littleEndian = try? box.payload.getInt(at: 0, as: UInt16.self) {
                    boxes.isLittleEndian = littleEndian != 0
                }
            case .esds: if boxes.esds == nil { boxes.esds = box }
            case .frma:
                guard let original = try? box.payload.getInt(at: 0, as: UInt32.self) else {
                    return false
                }
                // Protected formats name the original format in their `frma`.
                if format != .drms, format != .enca, original != rawFormat { return false }
            case .samr: if boxes.amrConfig == nil { boxes.amrConfig = box.payload }
            default: break
            }
        }
        return true
    }

    /// Boxes the entry's own fields or config replace, never kept as they are.
    private static let boxesNeverKept: Set<MP4Box.BoxType> = [
        .adrm, .alac, .chan, .dac3, .damr, .dec3, .dfLa, .esds, .free, .pcmC, .samr, .srat, .wave, .dOps,
    ]
}
