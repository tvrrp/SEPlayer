//
//  MP4Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMTime

final class MP4Extractor: Extractor {
    private let queue: Queue
    private let extractorOutput: ExtractorOutput
    private let boxParser = BoxParser()

    private var lastSniffFailures = [SniffFailure]()
    private var parserState: State = .readingAtomHeader
    private var bytesToEnqueue: Int = MP4Box.headerSize

    private var atomHeader: ByteBuffer
    private var atomHeaderBytesRead: Int = 0
    private var atomSize: UInt64 = 0
    private var atomType: UInt32 = 0

    private var atomData: ByteBuffer?
    private var seenFtypAtom: Bool = false
    private var containerAtoms: [ContainerBox] = []

    private var tracks: [MP4Track] = []
    private var accumulatedSampleSizes: [[Int]] = []
    private var sampleTrackIndex: Int?
    private var sampleBytesRead = 0
    private var sampleBytesWritten = 0

    private var duration: Int64 = .timeUnset

    init(queue: Queue, extractorOutput: ExtractorOutput) {
        self.queue = queue
        self.extractorOutput = extractorOutput
        self.atomHeader = ByteBuffer()
    }

    func shiff(input: any ExtractorInput) throws -> Bool {
        assert(queue.isCurrent())
        let sniffer = Sniffer()
        let result = try sniffer.sniffUnfragmented(input: input, acceptHeic: false)
        lastSniffFailures = [result].compactMap { $0 }

        return result == nil
    }

    func getSniffFailureDetails() -> [any SniffFailure] {
        assert(queue.isCurrent())
        return lastSniffFailures
    }

    func read(input: any ExtractorInput) throws -> ExtractorReadResult {
        assert(queue.isCurrent())
        while true {
            switch parserState {
            case .readingAtomHeader:
                if try !readAtomHeader(input: input) {
                    return .endOfInput
                }
            case .readingAtomPayload:
                let (position, seekRequired) = try readAtomPayload(input: input)
                if seekRequired {
                    return .seek(offset: position)
                }
            case .readingSample:
                return try readSample(input: input)
            }
        }
    }

    func seek(to position: Int, timeUs: Int64) {
        containerAtoms.removeAll()
        atomHeaderBytesRead = 0
        sampleTrackIndex = nil
        sampleBytesRead = 0
        sampleBytesWritten = 0
        if position == 0 {
            enterReadingAtomHeaderState()
        } else {
            for index in 0..<tracks.count {
                if let (updatedIndex, _) = tracks[index].sampleTable.syncSample(for: timeUs) {
                    tracks[index].sampleIndex = updatedIndex
                }
            }
        }
    }
}

extension MP4Extractor: SeekMap {
    func isSeekable() -> Bool {
        return true
    }

    func getDurationUs() -> Int64 {
        return duration
    }

    func getSeekPoints(for timeUs: Int64) -> SeekPoints {
        assert(parserState == .readingSample)
        return getSeekPoints(for: timeUs, trackId: nil)
    }

    func getSeekPoints(for time: Int64, trackId: Int?) -> SeekPoints {
        assert(parserState == .readingSample)
        guard !tracks.isEmpty else { return SeekPoints(first: .start) }
        var firstTime: Int64
        var firstOffset: Int
        var secondTime: Int64?
        var secondOffset: Int?

        let mainTrackIndex = trackId ?? tracks.firstIndex(where: { track in
            if case .video = track.track.format {
                return true
            }
            return false
        })

        if let mainTrackIndex {
            let mainTrack = tracks[mainTrackIndex]
            let sampleTable = mainTrack.sampleTable
            guard let (syncSampleIndex, syncSample) = sampleTable.syncSample(for: time) else {
                return SeekPoints(first: .start)
            }
            firstTime = syncSample.presentationTimeStampUs
            firstOffset = syncSample.offset
            
            if firstTime < time && syncSampleIndex < sampleTable.sampleCount - 1 {
                if let (_, secondSyncSample) = sampleTable.laterOrEqualSyncSample(for: time) {
                    secondTime = secondSyncSample.presentationTimeStampUs
                    secondOffset = secondSyncSample.offset
                }
            }
        } else {
            firstTime = time
            firstOffset = Int.max
        }

        if trackId == nil {
            let firstVideoTrackIndex = tracks.firstIndex(where: { track in
                if case .video = track.track.format {
                    return true
                }
                return false
            })
            for (index, track) in tracks.enumerated() {
                if index != firstVideoTrackIndex {
                    firstOffset = adjustSeekOffset(sampleTable: track.sampleTable, seekTime: firstTime, offset: firstOffset)
                    if let secondTime {
                        secondOffset.withTransform { offset in
                            offset = adjustSeekOffset(sampleTable: track.sampleTable, seekTime: secondTime, offset: offset)
                        }
                    }
                }
            }
        }

        let firstSeekPoint = SeekPoints.SeekPoint(timeUs: firstTime, position: firstOffset)
        let secondSeekPoint: SeekPoints.SeekPoint? = if let secondTime, let secondOffset {
            SeekPoints.SeekPoint(timeUs: secondTime, position: secondOffset)
        } else {
            nil
        }

        return SeekPoints(first: firstSeekPoint, second: secondSeekPoint)
    }
}

private extension MP4Extractor {
    private func readAtomHeader(input: ExtractorInput) throws -> Bool {
        assert(queue.isCurrent())
        if atomHeaderBytesRead == 0 {
            if try !input.readFully(to: &atomHeader, offset: 0, length: MP4Box.headerSize, allowEndOfInput: true) {
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
            try input.readFully(to: &atomHeader, offset: MP4Box.headerSize, length: headerBytesRemaining)
            atomHeaderBytesRead += headerBytesRemaining
            atomSize = try atomHeader.readInt(as: UInt64.self)
        } else if atomSize == MP4Box.extendsToEndSize {
            var endPosition = input.getLength()
            if endPosition == nil, let containerAtom = containerAtoms.first {
                endPosition = containerAtom.endPosition
            }

            if let endPosition {
                atomSize = UInt64(endPosition - input.getPosition() + atomHeaderBytesRead)
            }
        }

        guard atomSize >= atomHeaderBytesRead else {
            let reason = "Atom size less than header length unsupported"
            if let boxType = MP4Box.BoxType(rawValue: atomType) {
                throw BoxParser.BoxParserErrors.badBoxContent(type: boxType, reason: reason)
            } else {
                throw ParserException(unsupportedContainerFeature: reason)
            }
        }

        if shouldParseContainerAtom(atom: atomType) {
            let endPosition = input.getPosition() + Int(atomSize) - atomHeaderBytesRead
            if atomSize != atomHeaderBytesRead, atomType == MP4Box.BoxType.meta.rawValue {
                maybeSkipRemainingMetaAtomHeaderBytes(input: input)
            }
            containerAtoms.insert(.init(type: atomType, endPosition: endPosition), at: 0)
            if atomSize == atomHeaderBytesRead {
                try processAtomEnded(atomEndPosition: endPosition)
            } else {
                // Start reading first child atom
                enterReadingAtomHeaderState()
            }
        } else if shouldParseLeafAtom(atom: atomType) {
            guard atomHeaderBytesRead == MP4Box.headerSize, atomSize <= .max else {
                // TODO: throw error
                fatalError()
            }
//            atomData = ByteBuffer(buffer: atomHeader)
            atomData = atomHeader
            parserState = .readingAtomPayload
        } else {
            atomData = nil
            parserState = .readingAtomPayload
        }

        return true
    }

    private func readAtomPayload(input: ExtractorInput) throws -> (Int, Bool) {
        let atomPayloadSize = Int(atomSize) - atomHeaderBytesRead
        let atomEndPosition = input.getPosition() + atomPayloadSize
        var seekRequired = false
        var position: Int = 0

        if var atomData {
            try input.readFully(to: &atomData, offset: atomHeaderBytesRead, length: atomPayloadSize)
            if atomType == MP4Box.BoxType.ftyp.rawValue {
                seenFtypAtom = true
                // TODO: processFtypAtom
            } else if !containerAtoms.isEmpty {
                containerAtoms[0].add(LeafBox(type: atomType, data: atomData))
            }
        } else {
            if !seenFtypAtom, atomType == MP4Box.BoxType.mdat.rawValue {
                // TODO: fileType = .qt
            }
            if atomPayloadSize < .reloadMinimumSeekDistance {
                try input.skipFully(length: atomPayloadSize)
            } else {
                position = input.getPosition() + atomPayloadSize
                seekRequired = true
            }
        }

        try processAtomEnded(atomEndPosition: atomEndPosition)
        // TODO: seekToAxteAtom

        return (position, seekRequired && parserState != .readingSample)
    }

    func readSample(input: ExtractorInput) throws -> ExtractorReadResult {
        let inputPosition = input.getPosition()
        sampleTrackIndex = sampleTrackIndex ?? nextReadSample(inputPosition: inputPosition)

        guard let sampleTrackIndex else { return .endOfInput }

        let track = tracks[sampleTrackIndex]
        let trackOutput = track.trackOutput
        let sampleIndex = track.sampleIndex
        let sample = track.sampleTable.samples[sampleIndex]

        let skipAmount = sample.offset - inputPosition

        if skipAmount < 0 || skipAmount >= .reloadMinimumSeekDistance {
            return .seek(offset: sample.offset)
        }

        // TODO: sampleTransformation
        try input.skipFully(length: skipAmount)
        // TODO: canReadWithinGopSample
        while sampleBytesWritten < sample.size {
            let result = try trackOutput.loadSampleData(input: input, length: sample.size - sampleBytesWritten, allowEndOfInput: false)
            switch result {
            case let .success(writtenBytes):
                sampleBytesRead += writtenBytes
                sampleBytesWritten += writtenBytes
            case .endOfInput:
                // TODO: throw error
                fatalError()
            }
        }

        trackOutput.sampleMetadata(
            time: sample.presentationTimeStampUs,
            flags: sample.flags,
            size: sample.size,
            offset: 0
        )

        tracks[sampleTrackIndex].sampleIndex += 1
        self.sampleTrackIndex = nil
        sampleBytesRead = 0
        sampleBytesWritten = 0
//        isSampleDependedOn = false

        return .continueRead
    }
}

private extension MP4Extractor {
    func processMoovAtom(moov: ContainerBox) throws {
        var tracks = [MP4Track]()

//        let mvhdMetadata = try! BoxParser.Mp4TimestampData(
//            mvhd: moov.getLeafBoxOfType(type: .mvhd)?.data
//        )

        var gaplessInfoHolder = GaplessInfoHolder()
        let trackSampleTables = try! boxParser.parseTraks(
            moov: moov,
            gaplessInfoHolder: &gaplessInfoHolder,
            duration: .timeUnset,
            ignoreEditLists: false,
            isQuickTime: false
        )

        for (trackIndex, trackSampleTable) in trackSampleTables.enumerated() {
            guard trackSampleTable.sampleCount > 0 else { continue }
            let track = trackSampleTable.track
            let mp4Track = MP4Track(
                track: track,
                sampleTable: trackSampleTable,
                trackOutput: extractorOutput.track(
                    for: trackIndex,
                    trackType: track.type
                )
            )

            let trackDurationUs = track.durationUs != .timeUnset ? track.durationUs : trackSampleTable.durationUs
            mp4Track.trackOutput.setFormat(track.format.formatDescription)

            self.duration = max(duration, trackDurationUs)

            tracks.append(mp4Track)
        }

        self.tracks = tracks
        accumulatedSampleSizes = calculateAccumulatedSampleSizes(tracks: tracks)

        extractorOutput.endTracks()
        extractorOutput.seekMap(seekMap: self)
    }
}

private extension MP4Extractor {
    func processAtomEnded(atomEndPosition: Int) throws {
        while let first = containerAtoms.first, first.endPosition == atomEndPosition {
            let containerAtom = containerAtoms.removeFirst()
            if containerAtom.type == .moov {
                try! processMoovAtom(moov: containerAtom)
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

    func maybeSkipRemainingMetaAtomHeaderBytes(input: ExtractorInput) {
        
    }

    func enterReadingAtomHeaderState() {
        parserState = .readingAtomHeader
        atomHeaderBytesRead = 0
        atomHeader.clear(minimumCapacity: 16)
    }

    func nextReadSample(inputPosition: Int) -> Int? {
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

            let sampleOffset = track.sampleTable.samples[sampleIndex].offset
            let sampleAccumulatedBytes = accumulatedSampleSizes[trackIndex][sampleIndex]
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

    // TODO: I was lazy, need to rewrite
    func calculateAccumulatedSampleSizes(tracks: [MP4Track]) -> [[Int]] {
        var accumulatedSampleSizes = tracks.map { Array(repeating: 0, count: $0.sampleTable.sampleCount) }
        var nextSampleIndex = Array(repeating: 0, count: tracks.count)
        var nextSampleTimes = tracks.map { $0.sampleTable.samples[0].presentationTimeStampUs }
        var tracksFinished = Array(repeating: false, count: tracks.count)

        for (index, track) in tracks.enumerated() {
            accumulatedSampleSizes[index] = Array(repeating: 0, count: track.sampleTable.sampleCount)
            nextSampleTimes[index] = track.sampleTable.samples[0].presentationTimeStampUs
        }

        var accumulatedSampleSize = 0
        var finishedTracks = 0
        while finishedTracks < tracks.count {
            var minTime = Int64.max
            var minTimeTrackIndex = -1
            for i in 0..<tracks.count {
                if !tracksFinished[i] && nextSampleTimes[i] <= minTime {
                    minTimeTrackIndex = i
                    minTime = nextSampleTimes[i]
                }
            }
            var trackSampleIndex = nextSampleIndex[minTimeTrackIndex]
            accumulatedSampleSizes[minTimeTrackIndex][trackSampleIndex] = accumulatedSampleSize
            accumulatedSampleSize += tracks[minTimeTrackIndex].sampleTable.samples[trackSampleIndex].size
            trackSampleIndex += 1
            nextSampleIndex[minTimeTrackIndex] = trackSampleIndex
            if trackSampleIndex < accumulatedSampleSizes[minTimeTrackIndex].count {
                nextSampleTimes[minTimeTrackIndex] = tracks[minTimeTrackIndex].sampleTable.samples[trackSampleIndex].presentationTimeStampUs
            } else {
                tracksFinished[minTimeTrackIndex] = true
                finishedTracks += 2
            }
        }

        return accumulatedSampleSizes
    }

    func adjustSeekOffset(sampleTable: BoxParser.TrackSampleTable, seekTime: Int64, offset: Int) -> Int {
        if let (_, syncSample) = sampleTable.syncSample(for: seekTime) {
            return min(offset, syncSample.offset)
        } else {
            return offset
        }
    }
}

private extension MP4Extractor {
    enum State {
        case readingAtomHeader
        case readingAtomPayload
        case readingSample
    }

    struct MP4Track {
        let track: Track
        let sampleTable: BoxParser.TrackSampleTable
        let trackOutput: TrackOutput

        var sampleIndex: Int = 0
    }
}

private extension MP4Extractor {
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

private extension Int {
    static let reloadMinimumSeekDistance = 256 * 1024
    // For poorly interleaved streams, the maximum byte difference one track is allowed to be read
    // ahead before the source will be reloaded at a new position to read another track.
    static let maximumReadAheadBytesStream = 10 * 1024 * 1024
}

private extension BoxParser.TrackSampleTable {
    func syncSample(for time: Int64) -> (index: Int, sample: Sample)? {
        return earlierOrEqualSyncSample(for: time) ?? laterOrEqualSyncSample(for: time)
    }

    func earlierOrEqualSyncSample(for time: Int64) -> (index: Int, sample: Sample)? {
        guard let startIndex = samples.firstIndex(where: { $0.presentationTimeStampUs >= time}) else {
            return nil
        }

        for index in (0..<startIndex).reversed() {
            if samples[index].flags.contains(.keyframe) { return (index, samples[index]) }
        }

        return nil
    }

    func laterOrEqualSyncSample(for time: Int64) -> (index: Int, sample: Sample)? {
        guard let startIndex = samples.firstIndex(where: { $0.presentationTimeStampUs >= time}) else {
            return nil
        }

        for index in (startIndex..<samples.count) {
            if samples[index].flags.contains(.keyframe) { return (index, samples[index]) }
        }

        return nil
    }
}

