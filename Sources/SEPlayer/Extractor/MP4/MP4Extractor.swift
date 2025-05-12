//
//  MP4Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import CoreVideo
import Foundation

final class MP4Extractor: Extractor {
    private let queue: Queue
    private let extractorOutput: ExtractorOutput
    private let boxParser = BoxParser()

    private var parserState: State = .readingAtomHeader
    private var bytesToEnqueue: Int = MP4Box.headerSize

    private var atomHeader: ByteBuffer
    private var atomHeaderBytesRead: Int = 0
    private var atomSize: UInt32 = 0
    private var atomType: UInt32 = 0

    private var atomData: ByteBuffer?
    private var seenFtypAtom: Bool = false
    private var containerAtoms: [ContainerBox] = []

    private var tracks: [MP4Track] = []
    private var accumulatedSampleSizes: [[Int]] = []
    private var sampleTrackIndex: Int?
    private var sampleBytesRead = 0

    private var duration: Int64 = .timeUnset

    init(queue: Queue, extractorOutput: ExtractorOutput) {
        self.queue = queue
        self.extractorOutput = extractorOutput
        self.atomHeader = ByteBuffer()
    }

    func read(input: any ExtractorInput, completion: @escaping (ExtractorReadResult) -> Void) {
        let queue = queue
        assert(queue.isCurrent())
        switch parserState {
        case .readingAtomHeader:
            readAtomHeader(input: input) { error in
                assert(queue.isCurrent())
                if error != nil {
                    completion(.endOfInput)
                }
                completion(.continueRead)
            }
        case .readingAtomPayload:
            readAtomPayload(input: input) { result in
                assert(queue.isCurrent())
                switch result {
                case let .success(seekPosition):
                    if let seekPosition {
                        completion(.seek(offset: seekPosition))
                    } else {
                        completion(.continueRead)
                    }
                case let .failure(error):
                    completion(.error(error))
                }
            }
        case .readingSample:
            readSample(input: input, completion: completion)
        }
    }

    func seek(to position: Int, time: Int64) {
        containerAtoms.removeAll()
        atomHeaderBytesRead = 0
        sampleTrackIndex = nil
        if position == 0 {
            enterReadingAtomHeaderState()
        } else {
            for index in 0..<tracks.count {
                if let (index, _) = tracks[index].sampleTable.syncSample(for: time) {
                    tracks[index].sampleIndex = index
                }
            }
        }
    }
}

extension MP4Extractor: SeekMap {
    func isSeekable() -> Bool {
        return true
    }

    func getDuration() -> Int64 {
        queue.sync { return duration }
    }

    func getSeekPoints(for time: Int64) -> SeekPoints {
        queue.sync { return getSeekPoints(for: time, trackId: nil) }
    }

    func getSeekPoints(for time: Int64, trackId: Int?) -> SeekPoints {
        queue.sync {
            guard !tracks.isEmpty else { return SeekPoints(first: .start()) }
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
                    return SeekPoints(first: .start())
                }
                firstTime = syncSample.decodeTimeStamp
                firstOffset = syncSample.offset

                if firstTime < time && syncSampleIndex < sampleTable.sampleCount - 1 {
                    if let (_, secondSyncSample) = sampleTable.laterOrEqualSyncSample(for: time) {
                        secondTime = secondSyncSample.decodeTimeStamp
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

            let firstSeekPoint = SeekPoints.SeekPoint(time: firstTime, position: firstOffset)
            let secondSeekPoint: SeekPoints.SeekPoint? = if let secondTime, let secondOffset {
                SeekPoints.SeekPoint(time: secondTime, position: secondOffset)
            } else {
                nil
            }
            return SeekPoints(first: firstSeekPoint, second: secondSeekPoint)
        }
    }
}

private extension MP4Extractor {
    private func readAtomHeader(input: ExtractorInput, completion: @escaping (Error?) -> Void) {
        assert(queue.isCurrent())
        if atomHeaderBytesRead == 0 {
            input.read(to: atomHeader, offset: 0, length: MP4Box.headerSize) { [weak self] result in
                guard let self else { completion(DataReaderError.endOfInput); return }
                assert(queue.isCurrent())

                do {
                    switch result {
                    case let .bytesRead(buffer, _):
                        atomHeader = buffer
                        atomHeaderBytesRead = MP4Box.headerSize
                        atomSize = try atomHeader.readInt(as: UInt32.self)
                        atomType = try atomHeader.readInt(as: UInt32.self)
                        readAtomHeader(input: input, completion: completion)
                    case .endOfInput:
                        completion(DataReaderError.endOfInput)
                    }
                } catch {
                    completion(error)
                }
            }
            return
        }

        do {
            if shouldParseContainerAtom(atom: atomType) {
                let endPosition = input.getPosition() + Int(atomSize) - atomHeaderBytesRead
                if atomSize != atomHeaderBytesRead && atomType == MP4Box.BoxType.meta.rawValue {
                    maybeSkipRemainingMetaAtomHeaderBytes(input: input)
                }
                containerAtoms.insert(.init(type: atomType, endPosition: endPosition), at: 0)
                if atomSize == atomHeaderBytesRead {
                    try processAtomEnded(atomEndPosition: endPosition)
                } else {
                    // Читаем первый child atom
                    enterReadingAtomHeaderState()
                }
            } else if shouldParseLeafAtom(atom: atomType) {
                atomHeader.moveReaderIndex(to: 0)
                atomData = ByteBuffer(buffer: atomHeader)
                parserState = .readingAtomPayload
            } else {
                atomData = nil
                parserState = .readingAtomPayload
            }
            completion(nil)
        } catch {
            completion(error)
        }
    }

    private func readAtomPayload(input: ExtractorInput, completion: @escaping (Result<Int?, Error>) -> Void) {
        let atomPayloadSize = Int(atomSize) - atomHeaderBytesRead
        let atomEndPosition = input.getPosition() + atomPayloadSize
        var seekRequired = false
        var position: Int = 0

        func continueWork() {
            do {
                try processAtomEnded(atomEndPosition: atomEndPosition)
                if seekRequired && parserState != .readingSample {
                    completion(.success(position))
                } else {
                    completion(.success(nil))
                }
            } catch {
                completion(.failure(error))
            }
        }

        if let atomData {
            input.read(to: atomData, offset: atomHeaderBytesRead, length: atomPayloadSize) { [weak self] result in
                guard let self else { completion(.failure(DataReaderError.endOfInput)); return }
                assert(queue.isCurrent())
                switch result {
                case let .bytesRead(buffer, _):
                    self.atomData = buffer
                    if atomType == MP4Box.BoxType.ftyp.rawValue {
                        seenFtypAtom = true
                    } else if !containerAtoms.isEmpty {
                        containerAtoms[0].add(LeafBox(type: atomType, data: buffer))
                    }
                    continueWork()
                case .endOfInput:
                    completion(.failure(DataReaderError.endOfInput))
                }
            }
        } else {
            if atomPayloadSize < .reloadMinimumSeekDistance {
                input.skip(length: atomPayloadSize) { error in
                    if let error {
                        completion(.failure(error)); return
                    }
                    continueWork()
                }
            } else {
                position = input.getPosition() + atomPayloadSize
                seekRequired = true
                continueWork()
            }
        }
    }

    func readSample(input: ExtractorInput, completion: @escaping (ExtractorReadResult) -> Void) {
        let inputPosition = input.getPosition()
        guard let sampleTrackIndex else {
            self.sampleTrackIndex = nextReadSample(inputPosition: inputPosition)
            if self.sampleTrackIndex == nil { completion(.endOfInput); return }
            read(input: input, completion: completion); return
        }

        let track = tracks[sampleTrackIndex]
        let trackOutput = track.trackOutput
        let sampleIndex = track.sampleIndex
        let sample = track.sampleTable.samples[sampleIndex]

        let skipAmount = sample.offset - inputPosition

        if skipAmount < 0 || skipAmount >= .reloadMinimumSeekDistance {
            completion(.seek(offset: sample.offset))
            return
        }

        input.skip(length: skipAmount) { [weak self] error in
            guard let self else { return }
            if let error {
                completion(.error(error)); return
            }

            loadToTrackOutput(input: input, trackOutput: trackOutput, amount: sample.size) { error in
                if let error {
                    completion(.error(error))
                    return
                }

                trackOutput.sampleMetadata(
                    time: sample.decodeTimeStamp,
                    flags: sample.flags,
                    size: sample.size,
                    offset: 0
                )

                self.sampleBytesRead += sample.size
                self.sampleTrackIndex = nil
                self.tracks[sampleTrackIndex].sampleIndex += 1
                completion(.continueRead)
            }
//            trackOutput.sampleData(input: input, allowEndOfInput: false, metadata: sampleMedatada, completionQueue: self.queue) { error in
//                if let error {
//                    completion(.error(error)); return
//                }
//
//                self.sampleBytesRead += sample.size
//                self.sampleTrackIndex = nil
//                self.tracks[sampleTrackIndex].sampleIndex += 1
//                completion(.continueRead)
//            }
        }
    }

    func loadToTrackOutput(input: ExtractorInput, trackOutput: TrackOutput, amount: Int, completion: @escaping (Error?) -> Void) {
        trackOutput.loadSampleData(input: input, length: amount, completionQueue: queue) { [weak self] result in
            guard let self else { return }
            assert(queue.isCurrent())
            switch result {
            case let .success(loaded):
                let amountToLoad = max(0, amount - loaded)
                if amountToLoad > 0 {
                    loadToTrackOutput(input: input, trackOutput: trackOutput, amount: amountToLoad, completion: completion)
                } else {
                    completion(nil)
                }
            case let .failure(error):
                completion(error)
            }
        }
    }
}

private extension MP4Extractor {
    func processMoovAtom(moov: ContainerBox) throws {
        var tracks = [MP4Track]()

//        let mvhdMetadata = try BoxParser.Mp4TimestampData(
//            mvhd: moov.getLeafBoxOfType(type: .mvhd)?.data
//        )

        let trackSampleTables = try boxParser.parseTraks(moov: moov)

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
            let trackDuration = CMTime(
                value: CMTimeValue(track.duration),
                timescale: CMTimeScale(track.timescale)
            ).microseconds
            mp4Track.trackOutput.setFormat(track.format.formatDescription)

            self.duration = max(duration, trackDuration)

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
                try processMoovAtom(moov: containerAtom)
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
        var nextSampleTimes = tracks.map { $0.sampleTable.samples[0].decodeTimeStamp }
        var tracksFinished = Array(repeating: false, count: tracks.count)

        for (index, track) in tracks.enumerated() {
            accumulatedSampleSizes[index] = Array(repeating: 0, count: track.sampleTable.sampleCount)
            nextSampleTimes[index] = track.sampleTable.samples[0].decodeTimeStamp
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
                nextSampleTimes[minTimeTrackIndex] = tracks[minTimeTrackIndex].sampleTable.samples[trackSampleIndex].decodeTimeStamp
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
        atom == MP4Box.BoxType.moov.rawValue
            || atom == MP4Box.BoxType.trak.rawValue
            || atom == MP4Box.BoxType.mdia.rawValue
            || atom == MP4Box.BoxType.minf.rawValue
            || atom == MP4Box.BoxType.stbl.rawValue
            || atom == MP4Box.BoxType.edts.rawValue
            || atom == MP4Box.BoxType.meta.rawValue
    }

    func shouldParseLeafAtom(atom: UInt32) -> Bool {
        atom == MP4Box.BoxType.mdhd.rawValue
            || atom == MP4Box.BoxType.mvhd.rawValue
            || atom == MP4Box.BoxType.hdlr.rawValue
            || atom == MP4Box.BoxType.stsd.rawValue
            || atom == MP4Box.BoxType.stts.rawValue
            || atom == MP4Box.BoxType.stss.rawValue
            || atom == MP4Box.BoxType.ctts.rawValue
            || atom == MP4Box.BoxType.elst.rawValue
            || atom == MP4Box.BoxType.stsc.rawValue
            || atom == MP4Box.BoxType.stsz.rawValue
            || atom == MP4Box.BoxType.stz2.rawValue
            || atom == MP4Box.BoxType.stco.rawValue
            || atom == MP4Box.BoxType.co64.rawValue
            || atom == MP4Box.BoxType.tkhd.rawValue
            || atom == MP4Box.BoxType.ftyp.rawValue
            || atom == MP4Box.BoxType.udta.rawValue
            || atom == MP4Box.BoxType.keys.rawValue
            || atom == MP4Box.BoxType.ilst.rawValue
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
        guard let startIndex = samples.firstIndex(where: { $0.decodeTimeStamp >= time}) else {
            return nil
        }

        for index in (0..<startIndex).reversed() {
            if samples[index].flags.contains(.keyframe) { return (index, samples[index]) }
        }

        return nil
    }

    func laterOrEqualSyncSample(for time: Int64) -> (index: Int, sample: Sample)? {
        guard let startIndex = samples.firstIndex(where: { $0.decodeTimeStamp >= time}) else {
            return nil
        }

        for index in (startIndex..<samples.count) {
            if samples[index].flags.contains(.keyframe) { return (index, samples[index]) }
        }

        return nil
    }
}

