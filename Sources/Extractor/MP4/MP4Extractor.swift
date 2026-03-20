//
//  MP4Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMTime
import SEPlayerCommon

final class MP4Extractor: Extractor {
    public struct Flags: OptionSet {
        let rawValue: UInt8
        init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let workaroundIgnoreEditLists = Flags(rawValue: 1)
        public static let markFirstVideoTrackWithMainRole = Flags(rawValue: 1 << 2)
        public static let readWithinGopSampleDependencies = Flags(rawValue: 1 << 3)
        public static let readAuxiliaryTracks = Flags(rawValue: 1 << 4)
        public static let readWithinGopSampleDependenciesH265 = Flags(rawValue: 1 << 5)
        public static let omitTrackSampleTable = Flags(rawValue: 1 << 6)
    }

    private let queue: Queue
    private let subtitleParserFactory: SubtitleParserFactory
    private let flags: Flags
    private let omitTrackSampleTable: Bool
    private let boxParser = BoxParser()

    private var nalStartCode: ByteBuffer
    private var nalPrefix: ByteBuffer
    private var scratch: ByteBuffer

    private var atomHeader: ByteBuffer
    private var containerAtoms = [ContainerBox]()

    private var lastSniffFailures = [SniffFailure]()
    private var parserState: State = .readingAtomHeader
    private var atomType: UInt32 = 0
    private var atomSize: UInt64 = 0
    private var atomHeaderBytesRead: Int = 0
    private var atomData: ByteBuffer?

    private var sampleTrackIndex: Int?
    private var sampleBytesRead = 0
    private var sampleBytesWritten = 0
    private var sampleCurrentNalBytesRemaining = 0
    private var isSampleDependedOn = false
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
        subtitleParserFactory: SubtitleParserFactory,
        flags: Flags = []
    ) {
        self.queue = queue
        self.subtitleParserFactory = subtitleParserFactory
        self.flags = flags.union(.readWithinGopSampleDependencies)
        omitTrackSampleTable = flags.contains(.omitTrackSampleTable)
        extractorOutput = PlaceholderExtractorOutput()

        let allocator = ByteBufferAllocator()
        nalStartCode = ByteBuffer(bytes: NalUnitUtil.nalStartCode)
        nalPrefix = allocator.buffer(capacity: 6)
        scratch = ByteBuffer()
        atomHeader = allocator.buffer(capacity: MP4Box.fullHeaderSize)
    }

    public static func codecsToParseWithinGopSampleDependenciesAsFlags(_ videoCodecFlags: VideoCodecFlags) -> Flags {
        var flags = Flags()
        if videoCodecFlags.contains(.h264) {
            flags.insert(.readWithinGopSampleDependencies)
        }
        if videoCodecFlags.contains(.h265) {
            flags.insert(.readWithinGopSampleDependenciesH265)
        }

        return flags
    }

    func initialize(output: ExtractorOutput, isolation: isolated any Actor) throws {
        assert(queue.isCurrent())
        extractorOutput = SubtitleTranscodingExtractorOutput(
            delegate: output,
            subtitleParserFactory: subtitleParserFactory
        )
    }

    func shiff(input: any ExtractorInput, isolation: isolated any Actor) async throws -> Bool {
        assert(queue.isCurrent())
        let sniffFailures = try await Sniffer().sniffUnfragmented(input: input, isolation: isolation)
        if let sniffFailures {
            lastSniffFailures = [sniffFailures]
        }
        return sniffFailures == nil
    }

    func getSniffFailureDetails(isolation: isolated any Actor) -> [SniffFailure] {
        lastSniffFailures
    }

    func read(input: any ExtractorInput, isolation: isolated any Actor) async throws -> ExtractorReadResult {
        assert(queue.isCurrent())
        if omitTrackSampleTable, moovAtomProcessed {
            return .endOfInput
        }

        while true {
            switch parserState {
            case .readingAtomHeader:
                if try await !readAtomHeader(input: input, isolation: isolation) {
                    return .endOfInput
                }
            case .readingAtomPayload:
                let (position, seekRequired) = try await readAtomPayload(input: input, isolation: isolation)
                if seekRequired {
                    return .seek(offset: position)
                }
            case .readingSample:
                return try await readSample(input: input, isolation: isolation)
            }
        }
    }

    func seek(to position: Int, time: CMTime, isolation: isolated any Actor) throws {
        containerAtoms.removeAll()
        atomHeaderBytesRead = 0
        sampleTrackIndex = nil
        sampleBytesRead = 0
        sampleBytesWritten = 0
        sampleCurrentNalBytesRemaining = 0
        isSampleDependedOn = false
        moovAtomProcessed = false

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
    private func readAtomHeader(input: ExtractorInput, isolation: isolated any Actor) async throws -> Bool {
        assert(queue.isCurrent())
        if atomHeaderBytesRead == 0 {
            if try await !input.readFully(
                to: &atomHeader,
                offset: 0,
                length: MP4Box.headerSize,
                allowEndOfInput: true,
                isolation: isolation
            ) {
                // TODO: processEndOfStream
                return false
            }

            atomHeaderBytesRead = MP4Box.headerSize
            atomHeader.moveReaderIndex(to: .zero)
            atomSize = try! UInt64(atomHeader.readInt(as: UInt32.self))
            atomType = try! atomHeader.readInt(as: UInt32.self)
        }

        if atomSize == MP4Box.definesLargeSize {
            let headerBytesRemaining = MP4Box.longHeaderSize - MP4Box.headerSize
            try await input.readFully(
                to: &atomHeader,
                offset: MP4Box.headerSize,
                length: headerBytesRemaining,
                isolation: isolation
            )
            atomHeaderBytesRead += headerBytesRemaining
            atomSize = try atomHeader.readInt(as: UInt64.self)
        } else if atomSize == MP4Box.extendsToEndSize {
            var endPosition = input.getLength(isolation: isolation)
            if endPosition == nil, let containerAtom = containerAtoms.first {
                endPosition = containerAtom.endPosition
            }

            if let endPosition {
                atomSize = UInt64(endPosition - input.getPosition(isolation: isolation) + atomHeaderBytesRead)
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
            let endPosition = input.getPosition(isolation: isolation) + Int(atomSize) - atomHeaderBytesRead
            if atomSize != atomHeaderBytesRead, atomType == MP4Box.BoxType.meta.rawValue {
                maybeSkipRemainingMetaAtomHeaderBytes(input: input)
            }
            containerAtoms.insert(.init(type: atomType, endPosition: endPosition), at: 0)
            if atomSize == atomHeaderBytesRead {
                try processAtomEnded(atomEndPosition: endPosition, isolation: isolation)
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
            atomData = ByteBufferAllocator().buffer(buffer: atomHeader)
            parserState = .readingAtomPayload
        } else {
            atomData = nil
            parserState = .readingAtomPayload
        }

        return true
    }

    private func readAtomPayload(input: ExtractorInput, isolation: isolated any Actor) async throws -> (Int, Bool) {
        let atomPayloadSize = Int(atomSize) - atomHeaderBytesRead
        let atomEndPosition = input.getPosition(isolation: isolation) + atomPayloadSize
        var seekRequired = false
        var position: Int = 0

        if var atomData {
            try await input.readFully(
                to: &atomData,
                offset: atomHeaderBytesRead,
                length: atomPayloadSize,
                isolation: isolation
            )
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
                try await input.skipFully(length: atomPayloadSize, isolation: isolation)
            } else {
                position = input.getPosition(isolation: isolation) + atomPayloadSize
                seekRequired = true
            }
        }

        try processAtomEnded(atomEndPosition: atomEndPosition, isolation: isolation)
        // TODO: seekToAxteAtom

        return (position, seekRequired && parserState != .readingSample)
    }

    func readSample(input: ExtractorInput, isolation: isolated any Actor) async throws -> ExtractorReadResult {
        let inputPosition = input.getPosition(isolation: isolation)
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
        try await input.skipFully(length: skipAmount, isolation: isolation)
        if !canReadWithinGopSampleDependencies(format: track.track.format) {
            isSampleDependedOn = true
        }

        if track.track.nalUnitLengthFieldLength != 0 {
            let nalUnitLengthFieldLength = track.track.nalUnitLengthFieldLength
            while sampleBytesWritten < sampleSize {
                if sampleCurrentNalBytesRemaining == 0 {
                    // Read the NAL unit length field
                    var nalLengthBytes = ByteBuffer(repeating: 0, count: nalUnitLengthFieldLength)
                    try await input.readFully(
                        to: &nalLengthBytes,
                        offset: 0,
                        length: nalUnitLengthFieldLength,
                        isolation: isolation
                    )
                    sampleBytesRead += nalUnitLengthFieldLength

                    // Parse NAL unit length from the field (big-endian)
                    let nalLength: Int
                    switch nalUnitLengthFieldLength {
                    case 1: nalLength = Int(try nalLengthBytes.readInt(as: UInt8.self))
                    case 2: nalLength = Int(try nalLengthBytes.readInt(endianness: .big, as: UInt16.self))
                    case 4: nalLength = Int(try nalLengthBytes.readInt(endianness: .big, as: UInt32.self))
                    default: throw ParserError.createForMalformedContainer(message: "Invalid NAL length")
                    }

                    nalLengthBytes.moveReaderIndex(to: 0)
                    try trackOutput.sampleData(data: nalLengthBytes, length: nalUnitLengthFieldLength, isolation: isolation)
                    sampleBytesWritten += nalUnitLengthFieldLength

                    if !isSampleDependedOn {
                        let headerByteCount = NalUnitUtil.numberOfBytesInNalUnitHeader(format: track.track.format)
                        let remainingInSample = track.sampleTable.sizes[sampleIndex] - sampleBytesRead
                        if headerByteCount > 0 && headerByteCount <= remainingInSample {
                            var headerBytes = ByteBuffer(repeating: 0, count: headerByteCount)
                            try await input.readFully(to: &headerBytes, offset: 0, length: headerByteCount, isolation: isolation)
                            sampleBytesRead += headerByteCount

                            if NalUnitUtil.isDependedOn(
                                data: headerBytes,
                                offset: 0,
                                length: headerByteCount,
                                format: track.track.format
                            ) {
                                isSampleDependedOn = true
                            }

                            headerBytes.moveReaderIndex(to: 0)
                            try trackOutput.sampleData(data: headerBytes, length: headerByteCount, isolation: isolation)
                            sampleBytesWritten += headerByteCount
                            sampleCurrentNalBytesRemaining = nalLength - headerByteCount
                            continue
                        }
                    }

                    sampleCurrentNalBytesRemaining = nalLength
                } else {
                    let writtenBytes = try await trackOutput.loadSampleData(
                        input: input,
                        length: sampleCurrentNalBytesRemaining,
                        allowEndOfInput: false,
                        isolation: isolation
                    )
                    switch writtenBytes {
                    case let .success(writtenBytes):
                        sampleBytesRead += writtenBytes
                        sampleBytesWritten += writtenBytes
                        sampleCurrentNalBytesRemaining -= writtenBytes
                    case .endOfInput:
                        throw EndOfFileError()
                    }
                }
            }
        } else {
            while sampleBytesWritten < sampleSize {
                let result = try await trackOutput.loadSampleData(
                    input: input,
                    length: sampleSize - sampleBytesWritten,
                    allowEndOfInput: false,
                    isolation: isolation
                )
                switch result {
                case let .success(writtenBytes):
                    sampleBytesRead += writtenBytes
                    sampleBytesWritten += writtenBytes
                    sampleCurrentNalBytesRemaining -= writtenBytes
                case .endOfInput:
                    throw EndOfFileError()
                }
            }
        }

        let pts = track.sampleTable.pts[sampleIndex]
        let dts = track.sampleTable.dts[sampleIndex]
        let duration = track.sampleTable.durations[sampleIndex]
        var sampleFlags = track.sampleTable.flags[sampleIndex]
        if !isSampleDependedOn {
            sampleFlags.insert(.notDependedOn)
        }

        try trackOutput.sampleMetadata(
            time: .init(
                duration: duration,
                presentationTimeStamp: pts,
                decodeTimeStamp: dts
            ),
            flags: sampleFlags,
            size: sampleSize,
            offset: 0,
            isolation: isolation
        )

        track.sampleIndex += 1
        self.sampleTrackIndex = nil
        sampleBytesRead = 0
        sampleBytesWritten = 0
        sampleCurrentNalBytesRemaining = 0
        isSampleDependedOn = false

        return .continueRead
    }
}

private extension MP4Extractor {
    func processMoovAtom(moov: ContainerBox, isolation: isolated any Actor) throws {
        var firstVideoTrackIndex: Int?
        var duration = CMTime.invalid
        var tracks = [MP4Track]()

//        let mvhdMetadata = try! BoxParser.Mp4TimestampData(
//            mvhd: moov.getLeafBoxOfType(type: .mvhd)?.data
//        )

        var gaplessInfoHolder = GaplessInfoHolder()
        let trackSampleTables = try! boxParser.parseTraks(
            moov: moov,
            gaplessInfoHolder: &gaplessInfoHolder,
            duration: .invalid,
            ignoreEditLists: flags.contains(.workaroundIgnoreEditLists),
            isQuickTime: fileType == .quickTime,
            omitTrackSampleTable: omitTrackSampleTable
        )

        // TODO: if readingAuxiliaryTracks

        let containerMimeType = MimeTypes(from: trackSampleTables)
        for (trackIndex, trackSampleTable) in trackSampleTables.enumerated() {
            guard trackSampleTable.sampleCount > 0 else { continue }
            let track = trackSampleTable.track
            let mp4Track = MP4Track(
                track: track,
                sampleTable: trackSampleTable,
                trackOutput: try extractorOutput.track(
                    for: trackIndex,
                    trackType: track.type
                )
            )
            let trackDuration = track.duration.isValid ? track.duration : trackSampleTable.duration
            mp4Track.trackOutput.setDuration(trackDuration, isolation: isolation)
            duration = max(duration, trackDuration)

            let maxInputSize: Int = if track.format.sampleMimeType == .audioTRUEHD {
                trackSampleTable.maximumSize // TODO: size for TRUEHD
            } else {
                trackSampleTable.maximumSize
            }

            let formatBuilder = track.format.buildUpon()
            formatBuilder.setMaxInputSize(maxInputSize)

            if track.type == .video {
                var roleFlags = track.format.roleFlags
                if flags.contains(.markFirstVideoTrackWithMainRole) {
                    roleFlags.insert(firstVideoTrackIndex == nil ? .main : .alternate)
                }
                if readingAuxiliaryTracks {
                    roleFlags.insert(.auxiliary)
                    // TODO: formatBuilder.setAuxiliaryTrackType
                }
                formatBuilder.setRoleFlags(roleFlags)
            }
            formatBuilder.setContainerMimeType(containerMimeType)
            if track.format.sampleMimeType == .audioMPEG {
                mp4Track.pendingFormat = formatBuilder.build()
            } else {
                try mp4Track.trackOutput.setFormat(formatBuilder.build(), isolation: isolation)
            }

            if track.type == .video && firstVideoTrackIndex == nil {
                firstVideoTrackIndex = tracks.count
            }

            tracks.append(mp4Track)
        }

        self.tracks = tracks
        accumulatedSampleSizes = !omitTrackSampleTable ? calculateAccumulatedSampleSizes(tracks) : nil

        extractorOutput.endTracks()
        extractorOutput.seekMap(seekMap: Mp4SeekMap(
            duration: duration,
            tracks: self.tracks,
            firstVideoTrackIndex: firstVideoTrackIndex
        ))
    }
}

private extension MP4Extractor {
    func processAtomEnded(atomEndPosition: Int, isolation: isolated any Actor) throws {
        while let first = containerAtoms.first, first.endPosition == atomEndPosition {
            let containerAtom = containerAtoms.removeFirst()
            if containerAtom.type == .moov {
                try! processMoovAtom(moov: containerAtom, isolation: isolation)
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
        atomHeader.clear(minimumCapacity: 16)
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
        return condition ? preferredTrackIndex : minAccumulatedBytesTrackIndex
    }

    func maybeSkipRemainingMetaAtomHeaderBytes(input: ExtractorInput) {
        
    }

    func canReadWithinGopSampleDependencies(format: Format) -> Bool {
        switch format.sampleMimeType {
        case .videoH264:
            return flags.contains(.readWithinGopSampleDependencies)
        case .videoH265:
            return flags.contains(.readWithinGopSampleDependenciesH265)
        default:
            return false
        }
    }

    private func calculateAccumulatedSampleSizes(_ tracks: [MP4Track]) -> [[Int]] {
        var accumulatedSampleSizes = tracks.map { Array(repeating: 0, count: $0.sampleTable.sampleCount) }
        var nextSampleIndices = Array(repeating: 0, count: tracks.count)
        var nextSampleTimes = tracks.map { $0.sampleTable.pts[0] }
        var finishedTracks = Set<Int>()

        var accumulatedSize: Int = 0

        while finishedTracks.count < tracks.count {
            guard let minTrackIndex = tracks.indices
                .filter({ !finishedTracks.contains($0) })
                .min(by: { nextSampleTimes[$0] < nextSampleTimes[$1] })
            else { break }

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
    func processFtypAtom(atomData: inout ByteBuffer) throws -> FileType {
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
            .mdhd, .mvhd, .hdlr, .stsd, .stts, .stss, .ctts, .elst, .stsc, .stsz, .stz2, .stco, .co64, .tkhd, .ftyp, .udta, .keys, .ilst
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
        var pendingFormat: Format?

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
                for index in 0..<tracks.count {
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
    // For poorly interleaved streams, the maximum byte difference one track is allowed to be read
    // ahead before the source will be reloaded at a new position to read another track.
    static let maximumReadAheadBytesStream = 10 * 1024 * 1024
}

extension MimeTypes {
    init(from trackSampleTables: [TrackSampleTable]) {
        var hasAudio = false
        var imageMimeType: MimeTypes?

        for trackSampleTable in trackSampleTables {
            guard let sampleMimeType = trackSampleTable.track.format.sampleMimeType else {
                continue
            }

            if sampleMimeType.isVideo {
                self = .videoMP4; return
            }

            if sampleMimeType.isAudio {
                hasAudio = true
            } else if sampleMimeType.isImage {
                if sampleMimeType == .imageHEIC {
                    imageMimeType = .imageHEIF
                } else if sampleMimeType == .imageAVIF {
                    imageMimeType = sampleMimeType
                }
            }
        }

        if hasAudio {
            self = .audioMP4; return
        } else if let imageMimeType {
            self = imageMimeType; return
        }

        self = .applicationMP4; return
    }
}
