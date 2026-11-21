//
//  MP4Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMTime
import SEPlayerCommon

/// #if ExtractorMP4
final class MP4Extractor: Extractor {
    struct Flags: OptionSet {
        let rawValue: UInt8

        static let workaroundIgnoreEditLists = Flags(rawValue: 1)
        static let emitRawSubtitleData = Flags(rawValue: 1 << 1)
        static let markFirstVideoTrackWithMainRole = Flags(rawValue: 1 << 2)
        static let readWithinGopSampleDependencies = Flags(rawValue: 1 << 3)
        static let readAuxiliaryTracks = Flags(rawValue: 1 << 4)
        static let readWithinGopSampleDependenciesH265 = Flags(rawValue: 1 << 5)
        static let omitTrackSampleTable = Flags(rawValue: 1 << 6)
        /// Leaves the cover art out of the metadata.
        static let disableArtworkMetadata = Flags(rawValue: 1 << 7)
    }

    private let queue: Queue
    private let subtitleParserFactory: SubtitleParserFactory
    private let flags: Flags
    private let omitTrackSampleTable: Bool
    private let boxParser = BoxParser()

    ///    private var atomHeader: BlockBufferReader?
    private var containerAtoms = [ContainerBox]()

    private var lastSniffFailures = [SniffFailure]()
    private var parserState: State = .readingAtomHeader
    private var atomType: UInt32 = 0
    private var atomSize: UInt64 = 0
    private var atomHeaderBytesRead: Int = 0
    private var atomData: BlockBufferReader?

    private var sampleTrackIndex: Int?
    private var sampleBytesRead = 0
    private var sampleBytesWritten = 0
    private var sampleCurrentNalBytesRemaining = 0
    private var seenFtypAtom: Bool = false
    private var seekToAxteAtom = false
    private var readingAuxiliaryTracks = false
    private var moovAtomProcessed = false

    private var sampleOffsetForAuxiliaryTracks = Int.zero

    private var extractorOutput: ExtractorOutput
    private var tracks: [MP4Track] = []

    private var accumulatedSampleSizes: [[Int]]? = []
    private var fileType: FileType = .mp4

    init(
        queue: Queue,
        subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory(),
        flags: Flags = []
    ) {
        self.queue = queue
        self.subtitleParserFactory = subtitleParserFactory
        self.flags = flags.union([.readWithinGopSampleDependencies, .readWithinGopSampleDependenciesH265])
        omitTrackSampleTable = flags.contains(.omitTrackSampleTable)
        extractorOutput = PlaceholderExtractorOutput()
    }

    static func codecsToParseWithinGopSampleDependenciesAsFlags(_ videoCodecFlags: VideoCodecFlags) -> Flags {
        var flags = Flags()
        if videoCodecFlags.contains(.h264) {
            flags.insert(.readWithinGopSampleDependencies)
        }
        if videoCodecFlags.contains(.h265) {
            flags.insert(.readWithinGopSampleDependenciesH265)
        }

        return flags
    }

    func initialize(output: ExtractorOutput, _ isolation: isolated any Actor) async throws {
        assert(queue.isCurrent())
        extractorOutput = if flags.contains(.emitRawSubtitleData) {
            output
        } else {
            SubtitleTranscodingExtractorOutput(
                delegate: output,
                subtitleParserFactory: subtitleParserFactory
            )
        }
    }

    func sniff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        assert(queue.isCurrent())
        let sniffFailures = try await Sniffer().sniffUnfragmented(input: input, isolation)
        if let sniffFailures {
            lastSniffFailures = [sniffFailures]
        }
        return sniffFailures == nil
    }

    func getSniffFailureDetails(isolation: isolated any Actor) -> [SniffFailure] {
        lastSniffFailures
    }

    func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        assert(queue.isCurrent())
        if omitTrackSampleTable, moovAtomProcessed {
            return .endOfInput
        }

        while true {
            switch parserState {
            case .readingAtomHeader:
                if try await !readAtomHeader(input: input, isolation) {
                    return .endOfInput
                }
            case .readingAtomPayload:
                let (position, seekRequired) = try await readAtomPayload(input: input, isolation)
                if seekRequired {
                    return .seek(offset: position)
                }
            case .readingSample:
                return try await readSample(input: input, isolation)
            }
        }
    }

    func seek(to position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        containerAtoms.removeAll()
        atomHeaderBytesRead = 0
        sampleTrackIndex = nil
        sampleBytesRead = 0
        sampleBytesWritten = 0
        sampleCurrentNalBytesRemaining = 0
        moovAtomProcessed = false

        SELogger.debug(.mp4, "Seek to byte \(position) for \(time.seconds)")
        if position == 0 {
            enterReadingAtomHeaderState()
        } else {
            for track in tracks {
                let sampleIndex = track.sampleTable.earlierOrEqualSyncSample(for: time)
                    ?? track.sampleTable.laterOrEqualSyncSample(for: time)

                if let sampleIndex {
                    track.sampleIndex = sampleIndex
                }
            }
        }
    }
}

private extension MP4Extractor {
    private func readAtomHeader(input: ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        assert(queue.isCurrent())
        var atomHeader = try BlockBufferReader()
        if atomHeaderBytesRead == 0 {
            let (blockBuffer, endOfInput) = try await input.readFully(length: MP4Box.headerSize, allowEndOfInput: true, isolation)
            if endOfInput {
                // TODO: processEndOfStream
                return false
            }
            try atomHeader.extend(with: blockBuffer)
            atomHeaderBytesRead = MP4Box.headerSize
            atomSize = try UInt64(atomHeader.readInt(as: UInt32.self))
            atomType = try atomHeader.readInt(as: UInt32.self)
        }

        if atomSize == MP4Box.definesLargeSize {
            let headerBytesRemaining = MP4Box.longHeaderSize - MP4Box.headerSize
            try await atomHeader.extend(with: input.readFully(
                length: headerBytesRemaining,
                isolation
            ))
            atomHeaderBytesRead += headerBytesRemaining
            atomSize = try atomHeader.readInt(as: UInt64.self)
        } else if atomSize == MP4Box.extendsToEndSize {
            var endPosition = input.getLength(isolation)
            if endPosition == nil, let containerAtom = containerAtoms.first {
                endPosition = containerAtom.endPosition
            }

            if let endPosition {
                atomSize = UInt64(endPosition - input.getPosition(isolation) + atomHeaderBytesRead)
            }
        }

        if atomSize < atomHeaderBytesRead {
            if atomType == MP4Box.BoxType.free.rawValue {
                // Workaround for writers that could create a malformed 'free' box with a size less than
                // its header, causing file corruption.
                atomSize = UInt64(atomHeaderBytesRead)
            } else {
                let cause: Error? = if let boxType = MP4Box.BoxType(rawValue: atomType) {
                    BoxParser.BoxParserErrors.badBoxContent(type: boxType, reason: nil)
                } else {
                    nil
                }

                throw ParserError.createForUnsupportedContainerFeature(
                    message: "Atom size less than header length unsupported",
                    cause: cause
                )
            }
        }

        if shouldParseContainerAtom(atom: atomType) {
            let endPosition = input.getPosition(isolation) + Int(atomSize) - atomHeaderBytesRead
            if atomSize != atomHeaderBytesRead, atomType == MP4Box.BoxType.meta.rawValue {
                maybeSkipRemainingMetaAtomHeaderBytes(input: input)
            }
            containerAtoms.insert(.init(type: atomType, endPosition: endPosition), at: 0)
            if atomSize == atomHeaderBytesRead {
                try await processAtomEnded(atomEndPosition: endPosition, isolation)
            } else {
                // Start reading first child atom
                enterReadingAtomHeaderState()
            }
        } else if shouldParseLeafAtom(atom: atomType) {
            // We don't support parsing of leaf atoms that define extended atom sizes, or that have
            // lengths greater than Int.max.
            try checkArgument(atomHeaderBytesRead == MP4Box.headerSize)
            try checkArgument(atomSize <= .max)

            atomHeader.moveReaderIndex(to: 0)
            atomData = try BlockBufferReader(reader: atomHeader)
            parserState = .readingAtomPayload
        } else {
            atomData = nil
            parserState = .readingAtomPayload
        }

        return true
    }

    private func readAtomPayload(input: ExtractorInput, _ isolation: isolated any Actor) async throws -> (Int, Bool) {
        let atomPayloadSize = Int(atomSize) - atomHeaderBytesRead
        let atomEndPosition = input.getPosition(isolation) + atomPayloadSize
        var seekRequired = false
        var position = 0

        if var atomData {
            try await atomData.extend(with: input.readFully(length: atomPayloadSize, isolation))
//            try await input.readFully(
//                to: &atomData,
//                offset: atomHeaderBytesRead,
//                length: atomPayloadSize,
//                isolation: isolation
//            )
            if atomType == MP4Box.BoxType.ftyp.rawValue {
                seenFtypAtom = true
                fileType = try processFtypAtom(atomData: &atomData)
            } else if !containerAtoms.isEmpty {
                containerAtoms[0].add(LeafBox(type: atomType, data: atomData))
            }
        } else {
            if !seenFtypAtom, atomType == MP4Box.BoxType.mdat.rawValue {
                // The original QuickTime specification did not require files to begin with the ftyp atom.
                // See https://developer.apple.com/standards/qtff-2001.pdf.
                fileType = .quickTime
            }
            // We don't need the data. Skip or seek, depending on how large the atom is.
            if atomPayloadSize < .reloadMinimumSeekDistance {
                try input.skip(length: atomPayloadSize, isolation)
            } else {
                position = input.getPosition(isolation) + atomPayloadSize
                seekRequired = true
            }
        }

        try await processAtomEnded(atomEndPosition: atomEndPosition, isolation)
        // TODO: seekToAxteAtom

        return (position, seekRequired && parserState != .readingSample)
    }

    func readSample(input: ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        let inputPosition = input.getPosition(isolation)
        sampleTrackIndex = try sampleTrackIndex ?? nextReadSample(inputPosition: inputPosition)
        guard let sampleTrackIndex else { return .endOfInput }

        let track = tracks[sampleTrackIndex]
        let trackOutput = track.trackOutput
        let sampleIndex = track.sampleIndex
        let position = track.sampleTable.offsets[sampleIndex] + sampleOffsetForAuxiliaryTracks
        let sampleSize = track.sampleTable.sizes[sampleIndex]
        let skipAmount = position - inputPosition

        if skipAmount < 0 || skipAmount >= .reloadMinimumSeekDistance {
            return .seek(offset: position)
        }

        // TODO: sampleTransformation
        try input.skip(length: skipAmount, isolation)

        let blockBuffer = try await input.readFully(length: sampleSize, isolation)
        try trackOutput.sampleData(data: blockBuffer)

        let pts = track.sampleTable.pts[sampleIndex]
        let dts = track.sampleTable.dts[sampleIndex]
        let duration = track.sampleTable.durations[sampleIndex]
        var sampleFlags = track.sampleTable.flags[sampleIndex]
        if try !isSampleDependedOn(blockBuffer, track: track.track) {
            sampleFlags.insert(.notDependedOn)
        }

        try trackOutput.sampleMetadata(
            time: .init(
                duration: duration,
                presentationTimeStamp: pts,
                decodeTimeStamp: dts
            ),
            flags: sampleFlags,
            range: 0 ..< sampleSize
        )

        track.sampleIndex += 1
        self.sampleTrackIndex = nil
        sampleBytesRead = 0
        sampleBytesWritten = 0
        sampleCurrentNalBytesRemaining = 0

        return .continueRead
    }
}

private extension MP4Extractor {
    func processMoovAtom(moov: ContainerBox, _ isolation: isolated any Actor) async throws {
        var firstVideoTrackIndex: Int?
        var duration = CMTime.invalid
        var tracks = [MP4Track]()

        let mdtaMetadata = moov.getContainerBoxOfType(type: .meta).flatMap(boxParser.parseMdtaFromMeta(meta:))
        var gaplessInfoHolder = GaplessInfoHolder()
        var udtaMetadata: Metadata?
        if let udta = moov.getLeafBoxOfType(type: .udta) {
            let ignoreArtwork = flags.contains(.disableArtworkMetadata)
            let metadata = try boxParser.parseUdta(udtaBox: udta, ignoreArtwork: ignoreArtwork)
            gaplessInfoHolder.setFromMetadata(metadata)
            udtaMetadata = metadata
        }
        let mvhdMetadata = try moov.getLeafBoxOfType(type: .mvhd).map(boxParser.parseMvhd(mvhd:))

        let trackSampleTables = try boxParser.parseTraks(
            moov: moov,
            gaplessInfoHolder: &gaplessInfoHolder,
            durationTimeValue: nil,
            ignoreEditLists: flags.contains(.workaroundIgnoreEditLists),
            isQuickTime: fileType == .quickTime,
            omitTrackSampleTable: omitTrackSampleTable
        )

        // TODO: if readingAuxiliaryTracks

        let containerMimeType = MimeTypes(from: trackSampleTables)
        for (trackIndex, trackSampleTable) in trackSampleTables.enumerated() {
            guard trackSampleTable.sampleCount > 0 else { continue }
            let track = trackSampleTable.track
            let mp4Track = try MP4Track(
                track: track,
                sampleTable: trackSampleTable,
                trackOutput: extractorOutput.track(
                    for: trackIndex,
                    trackType: track.type
                )
            )
            let trackDuration = track.duration.isValid ? track.duration : trackSampleTable.duration
            mp4Track.trackOutput.setDuration(trackDuration)
            if duration.isValid {
                duration = max(duration, trackDuration)
            } else {
                duration = trackDuration
            }

            var format = track.format
            if track.type == .video {
                if flags.contains(.markFirstVideoTrackWithMainRole) {
                    format.roleFlags.insert(firstVideoTrackIndex == nil ? .main : .alternate)
                }
                if readingAuxiliaryTracks {
                    format.roleFlags.insert(.auxiliary)
                    // TODO: the type of the auxiliary track
                }
            }
            MetadataUtil.setFormatGaplessInfo(gaplessInfoHolder: gaplessInfoHolder, format: &format)
            MetadataUtil.setFormatMetadata(
                mdtaMetadata: mdtaMetadata,
                format: &format,
                additional: udtaMetadata,
                mvhdMetadata
            )
            format.containerMimeType = containerMimeType
            try mp4Track.trackOutput.setFormat(format)

            if track.type == .video && firstVideoTrackIndex == nil {
                firstVideoTrackIndex = tracks.count
            }

            SELogger.debug(.mp4, "Track \(track.id), \(track.type): \(trackSampleTable.sampleCount) samples, \(trackDuration.seconds)s, \(track.format)")
            tracks.append(mp4Track)
        }

        self.tracks = tracks
        accumulatedSampleSizes = !omitTrackSampleTable ? calculateAccumulatedSampleSizes(tracks) : nil
        SELogger.info(.mp4, "moov: \(tracks.count) tracks, \(duration.seconds)s\(fileType == .quickTime ? ", QuickTime" : "")")

        extractorOutput.endTracks()
        extractorOutput.seekMap(seekMap: Mp4SeekMap(
            duration: duration,
            tracks: self.tracks,
            firstVideoTrackIndex: firstVideoTrackIndex
        ))
    }
}

private extension MP4Extractor {
    func processAtomEnded(atomEndPosition: Int, _ isolation: isolated any Actor) async throws {
        while let first = containerAtoms.first, first.endPosition == atomEndPosition {
            let containerAtom = containerAtoms.removeFirst()
            if containerAtom.type == .moov {
                try await processMoovAtom(moov: containerAtom, isolation)
                containerAtoms.removeAll()
                parserState = .readingSample
            } else if !self.containerAtoms.isEmpty {
                containerAtoms[0].add(containerAtom)
            }
        }

        if parserState != .readingSample {
            enterReadingAtomHeaderState()
        }
    }

    func enterReadingAtomHeaderState() {
        parserState = .readingAtomHeader
        atomHeaderBytesRead = 0
    }

    func nextReadSample(inputPosition: Int) throws -> Int? {
        var preferredSkipAmount = Int.max
        var preferredRequiresReload = true
        var preferredTrackIndex: Int?
        var preferredAccumulatedBytes = Int.max
        var minAccumulatedBytes = Int.max
        var minAccumulatedBytesRequiresReload = true
        var minAccumulatedBytesTrackIndex: Int?

        for (trackIndex, track) in tracks.enumerated() {
            let sampleIndex = track.sampleIndex
            if sampleIndex == track.sampleTable.sampleCount {
                continue
            }

            let sampleOffset = track.sampleTable.offsets[sampleIndex]
            let sampleAccumulatedBytes = try accumulatedSampleSizes.checkNotNil()[trackIndex][sampleIndex]
            let skipAmount = sampleOffset - inputPosition
            let requiresReload = skipAmount < 0 || skipAmount >= .reloadMinimumSeekDistance
            if (!requiresReload && preferredRequiresReload) || (requiresReload == preferredRequiresReload && skipAmount < preferredSkipAmount) {
                preferredRequiresReload = requiresReload
                preferredSkipAmount = skipAmount
                preferredTrackIndex = trackIndex
                preferredAccumulatedBytes = sampleAccumulatedBytes
            }
            if sampleAccumulatedBytes < minAccumulatedBytes {
                minAccumulatedBytes = sampleAccumulatedBytes
                minAccumulatedBytesRequiresReload = requiresReload
                minAccumulatedBytesTrackIndex = trackIndex
            }
        }

        let condition = minAccumulatedBytes == Int.max || !minAccumulatedBytesRequiresReload || preferredAccumulatedBytes < minAccumulatedBytes + .maximumReadAheadBytesStream
        guard !condition else { return preferredTrackIndex }

        // Going back for the tracks that fell that far behind: to the one whose sample comes first in the file. The
        // others' samples then come after the input, and are read on the way, instead of left behind it. Coming back
        // from samples stored apart, as subtitles at the end of the file, the audio's next sample can come after the
        // video's: going back to the audio alone would leave the video behind until the audio ran another read-ahead
        // further.
        var earliestOffset = Int.max
        var earliestTrackIndex = minAccumulatedBytesTrackIndex
        for (trackIndex, track) in tracks.enumerated() where track.sampleIndex < track.sampleTable.sampleCount {
            let sampleAccumulatedBytes = try accumulatedSampleSizes.checkNotNil()[trackIndex][track.sampleIndex]
            let sampleOffset = track.sampleTable.offsets[track.sampleIndex]
            if preferredAccumulatedBytes >= sampleAccumulatedBytes + .maximumReadAheadBytesStream, sampleOffset < earliestOffset {
                earliestOffset = sampleOffset
                earliestTrackIndex = trackIndex
            }
        }
        return earliestTrackIndex
    }

    func maybeSkipRemainingMetaAtomHeaderBytes(input: ExtractorInput) {
        // TODO:
    }

    /// Whether a later frame may depend on the sample. Without reading the dependencies within a GOP for its codec,
    /// every sample may be depended on.
    private func isSampleDependedOn(_ sample: CMBlockBuffer, track: Track) throws -> Bool {
        guard canReadWithinGopSampleDependencies(format: track.format) else {
            return true
        }
        return try NalUnitUtil.isSampleDependedOn(
            BlockBufferReader(sample),
            nalUnitLengthFieldLength: track.nalUnitLengthFieldLength,
            format: track.format
        )
    }

    func canReadWithinGopSampleDependencies(format: AnyFormat) -> Bool {
        switch format.sampleMimeType {
        case .videoH264:
            flags.contains(.readWithinGopSampleDependencies)
        case .videoH265:
            flags.contains(.readWithinGopSampleDependenciesH265)
        default:
            false
        }
    }

    private func calculateAccumulatedSampleSizes(_ tracks: [MP4Track]) -> [[Int]] {
        var accumulatedSampleSizes = tracks.map { Array(repeating: 0, count: $0.sampleTable.sampleCount) }
        var nextSampleIndices = Array(repeating: 0, count: tracks.count)
        var nextSampleTimes = tracks.map { $0.sampleTable.pts[0] }
        var finishedTracks = Set<Int>()

        var accumulatedSize = 0

        while finishedTracks.count < tracks.count {
            guard let minTrackIndex = tracks.indices
                .filter({ !finishedTracks.contains($0) })
                .min(by: { nextSampleTimes[$0] < nextSampleTimes[$1] }) else { break }

            let sampleIndex = nextSampleIndices[minTrackIndex]
            accumulatedSampleSizes[minTrackIndex][sampleIndex] = accumulatedSize
            accumulatedSize += tracks[minTrackIndex].sampleTable.sizes[sampleIndex]

            let nextIndex = sampleIndex + 1
            nextSampleIndices[minTrackIndex] = nextIndex

            if nextIndex < accumulatedSampleSizes[minTrackIndex].count {
                nextSampleTimes[minTrackIndex] = tracks[minTrackIndex].sampleTable.pts[nextIndex]
            } else {
                finishedTracks.insert(minTrackIndex)
            }
        }

        return accumulatedSampleSizes
    }
}

private extension MP4Extractor {
    func processFtypAtom(atomData: inout BlockBufferReader) throws -> FileType {
        atomData.moveReaderIndex(to: MP4Box.headerSize)
        let majorBrand = try atomData.readInt(as: UInt32.self)
        var fileType = FileType(rawValue: majorBrand)

        if fileType != .mp4 {
            return fileType
        }

        atomData.moveReaderIndex(forwardBy: 4) // minor_version
        while atomData.readableBytes > 0 {
            fileType = try FileType(rawValue: atomData.readInt(as: UInt32.self))
            if fileType != .mp4 {
                return fileType
            }
        }

        return .mp4
    }

    func shouldParseContainerAtom(atom: UInt32) -> Bool {
        let atoms: [MP4Box.BoxType] = [.moov, .trak, .mdia, .minf, .stbl, .edts, .meta]
        return atoms.contains(where: { $0.rawValue == atom })
    }

    func shouldParseLeafAtom(atom: UInt32) -> Bool {
        let atoms: [MP4Box.BoxType] = [
            .mdhd, .mvhd, .hdlr, .stsd, .stts, .stss, .ctts, .elst, .stsc, .stsz, .stz2, .stco, .co64, .tkhd, .ftyp, .udta, .keys, .ilst,
        ]
        return atoms.contains(where: { $0.rawValue == atom })
    }
}

private extension MP4Extractor {
    enum State {
        case readingAtomHeader
        case readingAtomPayload
        case readingSample
    }

    final class MP4Track {
        let track: Track
        let sampleTable: TrackSampleTable
        let trackOutput: TrackOutput

        var sampleIndex: Int = 0

        init(track: Track, sampleTable: TrackSampleTable, trackOutput: TrackOutput) {
            self.track = track
            self.sampleTable = sampleTable
            self.trackOutput = trackOutput
        }
    }

    enum FileType {
        case mp4
        case quickTime

        init(rawValue: UInt32) {
            switch rawValue {
            case Sniffer.brandQuickTime:
                self = .quickTime
            default:
                self = .mp4
            }
        }
    }

    final class Mp4SeekMap: TrackAwareSeekMap {
        private let duration: CMTime
        private let tracks: [MP4Track]
        private let firstVideoTrackIndex: Int?

        init(duration: CMTime, tracks: [MP4Track], firstVideoTrackIndex: Int?) {
            self.duration = duration
            self.tracks = tracks
            self.firstVideoTrackIndex = firstVideoTrackIndex
        }

        func isSeekable() -> Bool { true }

        func isSeekable(trackId: Int) -> Bool { true }

        func getDuration() -> CMTime { duration }

        func getSeekPoints(for time: CMTime) -> SeekPoints {
            getSeekPoints(time: time, trackId: nil)
        }

        func getSeekPoints(time: CMTime, trackId: Int?) -> SeekPoints {
            guard !tracks.isEmpty else { return SeekPoints(first: .start) }

            var firstTime: CMTime
            var firstOffset: Int
            var secondTime: CMTime?
            var secondOffset: Int?

            // Note that the id matches the index in tracks.
            let mainTrackIndex = trackId ?? firstVideoTrackIndex
            // If we have a video track, use it to establish one or two seek points.
            if let mainTrackIndex {
                let sampleTable = tracks[mainTrackIndex].sampleTable
                guard let sampleIndex = getSyncSampleIndex(from: sampleTable, time: time) else {
                    return SeekPoints(first: .start)
                }

                let sampleTime = sampleTable.pts[sampleIndex]
                firstTime = sampleTime
                firstOffset = sampleTable.offsets[sampleIndex]

                if sampleTime < time && sampleIndex < sampleTable.sampleCount - 1 {
                    let secondSampleIndex = sampleTable.laterOrEqualSyncSample(for: time)
                    if let secondSampleIndex, secondSampleIndex != sampleIndex {
                        secondTime = sampleTable.pts[secondSampleIndex]
                        secondOffset = sampleTable.offsets[secondSampleIndex]
                    }
                }
            } else {
                firstTime = time
                firstOffset = Int.max
            }

            if trackId == nil {
                // Take into account other tracks, but only if the caller has not specified a trackId.
                for index in 0 ..< tracks.count {
                    if index != firstVideoTrackIndex {
                        let sampleTable = tracks[index].sampleTable
                        firstOffset = maybeAdjustSeekOffset(using: sampleTable, seekTime: firstTime, offset: firstOffset)
                        if let secondTime, let secondOffsetUnwrapped = secondOffset {
                            secondOffset = maybeAdjustSeekOffset(using: sampleTable, seekTime: secondTime, offset: secondOffsetUnwrapped)
                        }
                    }
                }
            }

            if let secondTime, let secondOffset {
                return SeekPoints(
                    first: .init(time: firstTime, position: firstOffset),
                    second: .init(time: secondTime, position: secondOffset)
                )
            } else {
                return SeekPoints(first: .init(time: firstTime, position: firstOffset))
            }
        }

        private func maybeAdjustSeekOffset(using sampleTable: TrackSampleTable, seekTime: CMTime, offset: Int) -> Int {
            guard let sampleIndex = getSyncSampleIndex(from: sampleTable, time: seekTime) else {
                return offset
            }

            let sampleOffset = sampleTable.offsets[sampleIndex]
            return min(sampleOffset, offset)
        }

        private func getSyncSampleIndex(from sampleTable: TrackSampleTable, time: CMTime) -> Int? {
            sampleTable.earlierOrEqualSyncSample(for: time) ?? sampleTable.laterOrEqualSyncSample(for: time)
        }
    }
}

private extension Int {
    static let reloadMinimumSeekDistance = 256 * 1024
    /// For poorly interleaved streams, the maximum byte difference one track is allowed to be read
    /// ahead before the source will be reloaded at a new position to read another track.
    static let maximumReadAheadBytesStream = 10 * 1024 * 1024
}

// #endif
