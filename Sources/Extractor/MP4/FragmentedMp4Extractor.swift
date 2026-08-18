//
//  FragmentedMp4Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.06.2025.

//#if ExtractorFMP4

import CoreMedia
import OrderedCollections
import SEPlayerCommon

public final class FragmentedMp4Extractor: Extractor {
    private let queue: Queue
    private let subtitleParserFactory: Void // TODO: add
    private let flags: Flags
    private let sideloadedTrack: Track?

    private let closedCaptionFormats: Array<Format>
    private var trackBundles: OrderedDictionary<Int, TrackBundle> = .init()

    private let timestampAdjuster: TimestampAdjuster?
    private let eventMessageEncoder: Void = ()

    private var containerAtoms: [ContainerBox] = []
    private var pendingMetadataSampleInfos: [Void] = [] // TODO: [MetadataSampleInfo]
    private var reorderingBufferQueue: [Void] = [] // TODO: ReorderingBufferQueue
    private var additionalEmsgTrackOutput: TrackOutput?

    private var chunkIndexMerger: ChunkIndexMerger

    private var lastSniffFailures: [SniffFailure] = []
    private var parserState: State = .readingAtomHeader
    private var atomType: MP4Box.BoxType?
    private var atomSize: UInt64 = 0
    private var atomHeaderBytesRead: Int = 0
    private var atomData: BlockBufferReader?
    private var endOfMdatPosition = 0
    private var pendingMetadataSampleBytes = 0
    private var pendingSeekTime: CMTime = .invalid

    private var duration: CMTime = .indefinite
    private var segmentIndexEarliestPresentationTime: CMTime = .invalid
    private var currentTrackBundle: TrackBundle?

    // maybe delete
    private var sampleSize = 0
    private var sampleBytesWritten = 0
    private var sampleCurrentNalBytesRemaining = 0
    private var isSampleDependedOn = false
    private var processSeiNalUnitPayload = false

    private var extractorOutput: ExtractorOutput
    private var emsgTrackOutputs: [TrackOutput] = []
    private var ceaTrackOutputs: [TrackOutput] = []

    private var haveOutputSeekMap = false
    private var upfrontSidxScanComplete = false
    private var seekPositionBeforeSidxProcessing: Int?

    private let boxParser = BoxParser()

    init(
        queue: Queue,
        flags: Flags = [],
        timestampAdjuster: TimestampAdjuster? = nil,
        sideloadedTrack: Track? = nil,
        closedCaptionFormats: [Format] = [],
        additionalEmsgTrackOutput: TrackOutput? = nil
    ) {
        self.queue = queue
        self.flags = flags
        self.timestampAdjuster = timestampAdjuster
        self.sideloadedTrack = sideloadedTrack
        self.closedCaptionFormats = closedCaptionFormats
        self.additionalEmsgTrackOutput = additionalEmsgTrackOutput
        extractorOutput = PlaceholderExtractorOutput()
        chunkIndexMerger = ChunkIndexMerger()
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

    public func shiff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        assert(queue.isCurrent())
        let sniffFailures = try await Sniffer().sniffFragmented(input: input, isolation)
        if let sniffFailures {
            lastSniffFailures = [sniffFailures]
        }
        return sniffFailures == nil
    }

    public func getSniffFailureDetails(_ isolation: isolated any Actor) -> [any SniffFailure] {
        assert(queue.isCurrent())
        return lastSniffFailures
    }

    public func initialize(output: any ExtractorOutput, _ isolation: isolated any Actor) async throws {
        // TODO: subtitles
        extractorOutput = output
        enterReadingAtomHeaderState()
        initExtraTracks()

        if let sideloadedTrack {
            let formatBuilder = sideloadedTrack.format.buildUpon()
            formatBuilder.setContainerMimeType(MimeTypes(format: sideloadedTrack.format))

            let bundle = try await TrackBundle(
                output: output.track(for: 0, trackType: sideloadedTrack.type),
                moovSampleTable: TrackSampleTable(
                    track: sideloadedTrack,
                    offsets: [],
                    sizes: [],
                    maximumSize: 0,
                    pts: [],
                    dts: [],
                    durations: [],
                    duration: .zero,
                    flags: [],
                    syncSampleIndices: [],
                    hasOnlySyncSamples: false,
                    sampleCount: 0
                ),
                defaultSampleValues: DefaultSampleValues(
                    sampleDescriptionIndex: 0,
                    durationTimeValue: 0,
                    size: 0,
                    flags: 0
                ),
                baseFormat: formatBuilder.build(),
                isolation
            )

            trackBundles[0] = bundle
            output.endTracks()
        }
    }

    public func seek(to position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        trackBundles.values.forEach { $0.resetFragmentInfo() }
        pendingMetadataSampleInfos.removeAll()
        pendingMetadataSampleBytes = .zero
        reorderingBufferQueue.removeAll()
        pendingSeekTime = time
        containerAtoms.removeAll()
        enterReadingAtomHeaderState()
    }

    public func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        assert(queue.isCurrent())
        while true {
            switch parserState {
            case .readingAtomHeader:
                if try await !readAtomHeader(input: input, isolation) {
                    if let seekPositionBeforeSidxProcessing {
                        self.seekPositionBeforeSidxProcessing = nil
                        extractorOutput.seekMap(seekMap: chunkIndexMerger.merge())
                        upfrontSidxScanComplete = true
                        return .seek(offset: seekPositionBeforeSidxProcessing)
                    } else {
                        // TODO: reorderingBufferQueue.flush()
                        return .endOfInput
                    }
                }
            case .readingAtomPayload:
                try await readAtomPayload(input: input, isolation)
            case .readingEncryptionData:
                try await readEncryptionData(input: input, isolation)
            default:
                if try await readSample(input: input, isolation) {
                    return .continueRead
                }
            }
        }
    }

    private func enterReadingAtomHeaderState() {
        assert(queue.isCurrent())
        parserState = .readingAtomHeader
        atomHeaderBytesRead = 0
    }

    private func readAtomHeader(input: ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        assert(queue.isCurrent())
        var atomHeader = try BlockBufferReader()
        if atomHeaderBytesRead == 0 {
            let (blockBuffer, endOfInput) = try await input.readFully(length: MP4Box.headerSize, allowEndOfInput: true, isolation)
            if endOfInput {
                return false
            }
            try atomHeader.extend(with: blockBuffer)
            atomHeaderBytesRead = MP4Box.headerSize
            atomSize = try UInt64(atomHeader.readInt(as: UInt32.self))
            atomType = try .init(rawValue: atomHeader.readInt(as: UInt32.self))
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
            try checkAtomArgument(
                atomType == .free && atomHeaderBytesRead == MP4Box.headerSize,
                message: "Atom size less than header length unsupported"
            )
            // Workaround for writers that could create a malformed 'free' box with a size less than
            // its header, causing file corruption.
            atomSize = UInt64(atomHeaderBytesRead)
        }

        if seekPositionBeforeSidxProcessing != nil {
            if atomType == .sidx {
                var scratch = try atomHeader.getSlice(at: 0, length: MP4Box.headerSize)
                try! await scratch.extend(with: input.readFully(
                    length: Int(atomSize) - atomHeaderBytesRead,
                    isolation
                ))

                let (_, chunkIndex) = try parseSidx(atom: &scratch, inputPosition: input.getPeekPosition(isolation))
                chunkIndexMerger.add(chunkIndex)
            } else {
                try! input.skip(
                    length: Int(atomSize) - atomHeaderBytesRead,
                    allowEndOfInput: true,
                    isolation
                )
            }
            enterReadingAtomHeaderState()
            return true
        }

        let atomPosition = input.getPosition(isolation) - atomHeaderBytesRead
        if atomType == .moof || atomType == .mdat {
            if !haveOutputSeekMap {
                extractorOutput.seekMap(seekMap: Unseekable(duration: duration, startPosition: atomPosition))
                haveOutputSeekMap = true
            }
        }

        if atomType == .moof {
            trackBundles.values.forEach {
                $0.fragment.atomPosition = atomPosition
                $0.fragment.auxiliaryDataPosition = atomPosition
                $0.fragment.dataPosition = atomPosition
            }
        }

        if atomType == .mdat {
            currentTrackBundle = nil
            endOfMdatPosition = atomPosition + Int(atomSize)
            parserState = .readingEncryptionData
            return true
        }

        if shouldParseContainerAtom(atom: atomType?.rawValue ?? 0) {
            let endPosition = input.getPosition(isolation) + Int(atomSize) - MP4Box.headerSize
            if atomSize != atomHeaderBytesRead && atomType == .meta {
                try await maybeSkipRemainingMetaAtomHeaderBytes(input: input, isolation)
            }
            containerAtoms.insert(.init(type: atomType?.rawValue ?? 0, endPosition: endPosition), at: 0)
            if atomSize == atomHeaderBytesRead {
                try await processAtomEnded(atomEndPosition: endPosition, isolation)
            } else {
                // Start reading the first child atom.
                enterReadingAtomHeaderState()
            }
        } else if shouldParseLeafAtom(atom: atomType?.rawValue ?? 0) {
            try checkAtomArgument(
                atomHeaderBytesRead == MP4Box.headerSize,
                message: "Leaf atom defines extended atom size (unsupported)."
            )
            try checkAtomArgument(
                atomSize <= Int32.max,
                message: "Leaf atom with length > 2147483647 (unsupported)."
            )

            atomHeader.moveReaderIndex(to: 0)
            atomData = try BlockBufferReader(reader: atomHeader, range: 0..<MP4Box.headerSize)
            parserState = .readingAtomPayload
        } else {
            try checkAtomArgument(
                atomSize <= Int32.max,
                message: "Skipping atom with length > 2147483647 (unsupported)"
            )

            atomData = nil
            parserState = .readingAtomPayload
        }

        return true
    }

    private func maybeSkipRemainingMetaAtomHeaderBytes(input: ExtractorInput, _ isolation: isolated any Actor) async throws {
        var meta = try BlockBufferReader()
        try await meta.extend(with: input.peekFully(
            length: MP4Box.headerSize,
            isolation
        ))
        try boxParser.maybeSkipRemainingMetaBoxHeaderBytes(meta: &meta)
        try input.skip(length: meta.readerIndex, isolation)
        input.resetPeekPosition(isolation)
    }

    private func readAtomPayload(input: ExtractorInput, _ isolation: isolated any Actor) async throws {
        let atomPayloadSize = Int(atomSize) - atomHeaderBytesRead

        if let atomData {
            try await atomData.extend(with: input.readFully(
                length: atomPayloadSize,
                isolation
            ))
            try onLeafAtomRead(
                leaf: LeafBox(type: atomType?.rawValue ?? 0, data: atomData),
                inputPosition: input.getPosition(isolation)
            )
        } else {
            try input.skip(length: atomPayloadSize, isolation)
        }

        try await processAtomEnded(atomEndPosition: input.getPosition(isolation), isolation)
    }

    private func processAtomEnded(atomEndPosition: Int, _ isolation: isolated any Actor) async throws {
        while !containerAtoms.isEmpty, containerAtoms.first?.endPosition == atomEndPosition {
            try await onContainerAtomRead(container: containerAtoms.removeFirst(), isolation)
        }
        enterReadingAtomHeaderState()
    }

    private func onLeafAtomRead(leaf: LeafBox, inputPosition: Int) throws {
        if !containerAtoms.isEmpty {
            containerAtoms[0].add(leaf)
        } else if leaf.type == .sidx {
            var data = leaf.data
            let (time, chunkIndex) = try parseSidx(atom: &data, inputPosition: inputPosition)
            chunkIndexMerger.add(chunkIndex)
            segmentIndexEarliestPresentationTime = time
            if !upfrontSidxScanComplete {
                extractorOutput.seekMap(
                    seekMap: chunkIndexMerger.count == 1 ? chunkIndex : chunkIndexMerger.merge()
                )
                haveOutputSeekMap = true
            }

            if flags.contains(.mergeFragmentedSidx),
               !upfrontSidxScanComplete,
               chunkIndexMerger.count > 1 {
                seekPositionBeforeSidxProcessing = inputPosition
            }
        } else if leaf.type == .emsg {
            try onEmsgLeafAtomRead(atom: leaf.data)
        }
    }

    private func onContainerAtomRead(container: ContainerBox, _ isolation: isolated any Actor) async throws {
        if container.type == .moov {
            try await onMoovContainerAtomRead(moov: container, isolation)
        } else if container.type == .moof {
            try onMoofContainerAtomRead(moof: container)
        } else if !containerAtoms.isEmpty {
            containerAtoms[0].add(container)
        }
    }

    private func onMoovContainerAtomRead(moov: ContainerBox, _ isolation: isolated any Actor) async throws {
        guard sideloadedTrack == nil else {
            throw ParserError.createForMalformedContainer(message: "Unexpected moov box.")
        }

        // TODO: drmInitData
        let mvex = try! moov.getContainerBoxOfType(type: .mvex)
            .checkNotNil(BoxParser.BoxParserErrors.missingBox(type: .mvex))
        var defaultSampleValuesArray = [Int: DefaultSampleValues]()
        var durationTimeValue: CMTimeValue?

        for leafChild in mvex.leafChildren {
            if leafChild.type == .trex {
                var trex = leafChild.data
                let (trackId, defaultSampleValues) = try parseTrex(trex: &trex)
                defaultSampleValuesArray[trackId] = defaultSampleValues
            } else if leafChild.type == .mehd {
                var mehd = leafChild.data
                durationTimeValue = try parseMehd(mehd: &mehd)
            }
        }

        // TODO: mdtaMetadata

        var gaplessInfoHolder = GaplessInfoHolder()

        // TODO: mdtaMetadata

        let sampleTables = try boxParser.parseTraks(
            moov: moov,
            gaplessInfoHolder: &gaplessInfoHolder,
            durationTimeValue: durationTimeValue,
            ignoreEditLists: flags.contains(.workaroundIgnoreEditLists),
            isQuickTime: false,
            omitTrackSampleTable: false
        )

        if trackBundles.isEmpty {
            let containerMimeType = MimeTypes(from: sampleTables)
            for sampleTable in sampleTables {
                let track = sampleTable.track
                let output = try extractorOutput.track(for: track.id, trackType: track.type)
                await output.setDuration(track.duration, isolation: output.isolation)
                let formatBuilder = track.format.buildUpon()
                formatBuilder.setContainerMimeType(containerMimeType)
                // TODO: MetadataUtil.setFormatGaplessInfo
                // TODO: MetadataUtil.setFormatMetadata

                let trackBundle = try await TrackBundle(
                    output: output,
                    moovSampleTable: sampleTable,
                    defaultSampleValues: try getDefaultSampleValues(
                        defaultSampleValues: defaultSampleValuesArray,
                        trackId: track.id
                    ),
                    baseFormat: formatBuilder.build(),
                    isolation
                )

                trackBundles[track.id] = trackBundle
                if duration.isNumeric {
                    duration = max(duration, track.duration)
                } else {
                    duration = track.duration
                }
            }

            extractorOutput.endTracks()
        } else {
            assert(trackBundles.count == sampleTables.count)
            for sampleTable in sampleTables {
                let track = sampleTable.track
                try await trackBundles[track.id]?.reset(
                    moovSampleTable: sampleTable,
                    defaultSampleValues: try getDefaultSampleValues(
                        defaultSampleValues: defaultSampleValuesArray,
                        trackId: track.id
                    ),
                    isolation
                )
            }
        }
    }

    private func getDefaultSampleValues(
        defaultSampleValues: [Int: DefaultSampleValues],
        trackId: Int
    ) throws -> DefaultSampleValues {
        if defaultSampleValues.count == 1 {
            // Ignore track id if there is only one track to cope with non-matching track indices.
            return defaultSampleValues.first!.value
        }

        if let result = defaultSampleValues[trackId] {
            return result
        } else {
            fatalError() // TODO: throw error
        }
    }

    private func onMoofContainerAtomRead(moof: ContainerBox) throws {
        try parseMoof(
            moof: moof,
            trackBundles: trackBundles,
            haveSideloadedTrack: sideloadedTrack != nil,
            flags: flags
        )

        // TODO: DRM INIT DATA

        // If we have a pending seek, advance tracks to their preceding sync frames.
        if pendingSeekTime.isValid {
            trackBundles.values.forEach { $0.seek(to: pendingSeekTime) }
            pendingSeekTime = .invalid
        }
    }

    private func initExtraTracks() {
        // TODO: impl
    }

    private func onEmsgLeafAtomRead(atom: BlockBufferReader) throws {
        // TODO: impl
    }

    private func parseTrex(trex: inout BlockBufferReader) throws -> (Int, DefaultSampleValues) {
        trex.moveReaderIndex(to: MP4Box.fullHeaderSize)
        let trackId = try Int(trex.readInt(as: UInt32.self))
        let defaultSampleDescriptionIndex = try Int(trex.readInt(as: UInt32.self)) - 1
        let defaultSampleDuration = try CMTimeValue(trex.readInt(as: UInt32.self))
        let defaultSampleSize = try Int(trex.readInt(as: UInt32.self))
        let defaultSampleFlags = try Int(trex.readInt(as: UInt32.self))

        return (trackId, DefaultSampleValues(
            sampleDescriptionIndex: defaultSampleDescriptionIndex,
            durationTimeValue: defaultSampleDuration,
            size: defaultSampleSize,
            flags: defaultSampleFlags
        ))
    }

    private func parseMehd(mehd: inout BlockBufferReader) throws -> CMTimeValue {
        mehd.moveReaderIndex(to: MP4Box.headerSize)
        let (version, _) = try BoxParser.readFullboxExtra(reader: &mehd)
        return try version == 0 ? Int64(mehd.readInt(as: UInt32.self)) : Int64(mehd.readInt(as: UInt64.self))
    }

    private func parseMoof(
        moof: ContainerBox,
        trackBundles: OrderedDictionary<Int, TrackBundle>,
        haveSideloadedTrack: Bool,
        flags: Flags
    ) throws {
        for child in moof.containerChildren {
            if child.type == .traf {
                try parseTraf(
                    traf: child,
                    trackBundles: trackBundles,
                    haveSideloadedTrack: haveSideloadedTrack,
                    flags: flags
                )
            }
        }
    }

    private func parseTraf(
        traf: ContainerBox,
        trackBundles: OrderedDictionary<Int, TrackBundle>,
        haveSideloadedTrack: Bool,
        flags: Flags
    ) throws {
        var tfhd = try traf.getLeafBoxOfType(type: .tfhd)
            .checkNotNil(BoxParser.BoxParserErrors.missingBox(type: .tfhd))
            .data

        let trackBundle = try parseTfhd(tfhd: &tfhd, trackBundles: trackBundles, haveSideloadedTrack: haveSideloadedTrack)
        guard let trackBundle else { return }

        var fragment = trackBundle.fragment
        let fragmentDecodeTime = fragment.nextFragmentDecodeTime
        let fragmentDecodeTimeIncludesMoov = fragment.nextFragmentDecodeTimeIncludesMoov
        trackBundle.resetFragmentInfo()
        trackBundle.currentlyInFragment = true

        let tfdtAtom = traf.getLeafBoxOfType(type: .tfdt)?.data
        if var tfdtAtom, !flags.contains(.workaroundIgnoreTfdtBox) {
            fragment.nextFragmentDecodeTime = try parseTfdt(tfdt: &tfdtAtom)
            fragment.nextFragmentDecodeTimeIncludesMoov = true
        } else {
            fragment.nextFragmentDecodeTime = fragmentDecodeTime
            fragment.nextFragmentDecodeTimeIncludesMoov = fragmentDecodeTimeIncludesMoov
        }

        try parseTruns(traf: traf, trackBundle: trackBundle, flags: flags)

        // TODO: encryptionBox

        try parseSampleGroups(traf: traf, schemeType: nil, out: &fragment)
        for leafChild in traf.leafChildren {
            if leafChild.type == .uuid {
                var leafData = leafChild.data
                try parseUUID(uuid: &leafData, out: &fragment)
            }
        }
    }

    private func parseTruns(
        traf: ContainerBox,
        trackBundle: TrackBundle,
        flags: Flags
    ) throws {
        var trunCount = 0
        var totalSampleCount = 0

        for leafChild in traf.leafChildren where leafChild.type == .trun {
            var trunData = leafChild.data
            trunData.moveReaderIndex(to: MP4Box.fullHeaderSize)
            let trunSampleCount = try trunData.readInt(as: UInt32.self)
            if trunSampleCount > 0 {
                totalSampleCount += Int(trunSampleCount)
                trunCount += 1
            }
        }

        trackBundle.currentTrackRunIndex = 0
        trackBundle.currentSampleInTrackRun = 0
        trackBundle.currentSampleIndex = 0
        trackBundle.fragment.initTables(trunCount: trunCount, sampleCount: totalSampleCount)

        var trunIndex = 0
        var trunStartPosition = 0

        for leafChild in traf.leafChildren where leafChild.type == .trun {
            var trun = leafChild.data
            trunStartPosition = try parseTrun(
                trackBundle: trackBundle,
                index: trunIndex,
                flags: flags,
                trun: &trun,
                trackRunStart: trunStartPosition
            )
            trunIndex += 1
        }
    }

    private func parseSaiz() {
        fatalError()
    }

    private func parseSaio(saio: inout BlockBufferReader, out: inout TrackFragment) throws {
        saio.moveReaderIndex(to: MP4Box.headerSize)
        let (version, flags) = try BoxParser.readFullboxExtra(reader: &saio)
        if (flags & 0x01) == 1 {
            saio.moveReaderIndex(forwardBy: 8)
        }

        let entryCount = try saio.readInt(as: UInt32.self)
        if entryCount != 1 {
            // We only support one trun element currently, so always expect one entry.
            throw ParserError.createForMalformedContainer(
                message: "Unexpected saio entry count: \(entryCount)"
            )
        }

        let value = if version == 0 {
            try Int(saio.readInt(as: UInt32.self))
        } else {
            try Int(saio.readInt(as: UInt64.self))
        }
        out.auxiliaryDataPosition += value
    }

    private func parseTfhd(
        tfhd: inout BlockBufferReader,
        trackBundles: OrderedDictionary<Int, TrackBundle>,
        haveSideloadedTrack: Bool
    ) throws -> TrackBundle? {
        tfhd.moveReaderIndex(to: MP4Box.headerSize)
        let (_, atomFlags) = try BoxParser.readFullboxExtra(reader: &tfhd)
        let trackId = try Int(tfhd.readInt(as: UInt32.self))
        let trackBundle = haveSideloadedTrack ? trackBundles.values[0] : trackBundles[trackId]

        guard let trackBundle else { return nil }

        if (atomFlags & 0x01) != 0 { // base_data_offset_present
            let baseDataPosition = try Int(tfhd.readInt(as: UInt64.self))
            trackBundle.fragment.dataPosition = baseDataPosition
            trackBundle.fragment.auxiliaryDataPosition = baseDataPosition
        }

        let defaultSampleValues = trackBundle.defaultSampleValues

        let defaultSampleDescriptionIndex = if (atomFlags & 0x02) != 0 { // default_sample_description_index_present
            try Int(tfhd.readInt(as: UInt32.self)) - 1
        } else {
            defaultSampleValues.sampleDescriptionIndex
        }

        let defaultSampleDuration: CMTimeValue = if (atomFlags & 0x08) != 0 { // default_sample_duration_present
            try CMTimeValue(tfhd.readInt(as: UInt32.self))
        } else {
            defaultSampleValues.durationTimeValue
        }

        let defaultSampleSize = if (atomFlags & 0x10) != 0 { // default_sample_size_present
            try Int(tfhd.readInt(as: UInt32.self))
        } else {
            defaultSampleValues.size
        }

        let defaultSampleFlags = if (atomFlags & 0x20) != 0 { // default_sample_flags_present
            try Int(tfhd.readInt(as: UInt32.self))
        } else {
            defaultSampleValues.flags
        }

        trackBundle.fragment.header = .init(
            sampleDescriptionIndex: defaultSampleDescriptionIndex,
            durationTimeValue: defaultSampleDuration,
            size: defaultSampleSize,
            flags: defaultSampleFlags
        )

        return trackBundle
    }

    private func parseTfdt(tfdt: inout BlockBufferReader) throws -> CMTimeValue {
        tfdt.moveReaderIndex(to: MP4Box.headerSize)
        let (version, _) = try BoxParser.readFullboxExtra(reader: &tfdt)

        if version == 1 {
            return try CMTimeValue(tfdt.readInt(as: UInt64.self))
        } else {
            return try CMTimeValue(tfdt.readInt(as: UInt32.self))
        }
    }

    private func isEdtsListDurationForEntireMediaTimeline(track: Track) -> Bool {
        // Currently we only support a single edit that moves the entire media timeline (indicated by
        // duration == 0 or (editListDuration + editListMediaTime) >= track duration.
        // Other uses of edit lists are uncommon and unsupported.
        guard let editListDurations = track.editListDurations,
              editListDurations.count == 1,
              let editListMediaTimes = track.editListMediaTimes,
              !editListMediaTimes.isEmpty else {
            return false
        }

        if editListDurations[0] == 0 { return true }

        // Edit list durations are expressed in the movie timescale; edit list media times are
        // expressed in the track's media timescale. They are not interchangeable.
        let editListDuration = CMTime(value: editListDurations[0], timescale: track.movieTimescale)
        let editListMediaTime = CMTime(value: editListMediaTimes[0], timescale: track.timescale)

        guard editListDuration.isNumeric,
              editListMediaTime.isNumeric,
              track.duration.isNumeric else {
            return false
        }

        return editListDuration + editListMediaTime >= track.duration
    }

    private func parseTrun(
        trackBundle: TrackBundle,
        index: Int,
        flags: Flags,
        trun: inout BlockBufferReader,
        trackRunStart: Int
    ) throws -> Int {
        trun.moveReaderIndex(to: MP4Box.headerSize)
        let (_, atomFlags) = try BoxParser.readFullboxExtra(reader: &trun)
        let track = trackBundle.moovSampleTable.track
        let fragment = trackBundle.fragment
        let defaultSampleValues = try fragment.header.checkNotNil()

        fragment.trunLength[index] = try Int(trun.readInt(as: UInt32.self))
        fragment.trunDataPosition[index] = fragment.dataPosition
        if (atomFlags & 0x01) != 0 { // data_offset_present
            fragment.trunDataPosition[index] += try Int(trun.readInt(as: Int32.self))
        }

        let firstSampleFlagsPresent = (atomFlags & 0x04) != 0 // first_sample_flags_present
        var firstSampleFlags = defaultSampleValues.flags
        if firstSampleFlagsPresent {
            firstSampleFlags = try Int(trun.readInt(as: UInt32.self))
        }

        let sampleDurationsPresent = (atomFlags & 0x100) != 0 // sample_duration_present
        let sampleSizesPresent = (atomFlags & 0x200) != 0 // sample_size_present
        let sampleFlagsPresent = (atomFlags & 0x400) != 0 // sample_flags_present
        let sampleCompositionTimeOffsetsPresent = (atomFlags & 0x800) != 0 // sample_composition_time_offsets_present

        let timescale = track.timescale

        // Offset to the entire video timeline. In the presence of B-frames this is usually used to
        // ensure that the first frame's presentation timestamp is zero.
        var edtsOffset: CMTimeValue = 0

        // Currently we only support a single edit that moves the entire media timeline.
        if isEdtsListDurationForEntireMediaTimeline(track: track) {
            edtsOffset = try track.editListMediaTimes.checkNotNil()[0]
        }

        // Single offset applied to both decode and presentation timelines, expressed once in the
        // track timescale so every emitted CMTime shares one epoch and one scale.
        var timelineOffset: CMTimeValue = -edtsOffset
        if !fragment.nextFragmentDecodeTimeIncludesMoov {
            let moovDuration = trackBundle.moovSampleTable.duration
            timelineOffset += moovDuration.convertScale(timescale, method: .default).value
        }

        var sampleSizeTable = fragment.sampleSizeTable
        var sampleDecodeTimes = fragment.sampleDecodeTimes
        var samplePresentationTimes = fragment.samplePresentationTimes
        var sampleDurations = fragment.sampleDurations
        var sampleIsSyncFrameTable = fragment.sampleIsSyncFrameTable

        let workaroundEveryVideoFrameIsSyncFrame = track.type == .video
        && flags.contains(.workaroundEveryVideoFrameIsSyncFrame)

        let trackRunEnd = trackRunStart + fragment.trunLength[index]
        var cumulativeTime = fragment.nextFragmentDecodeTime

        for sampleIndex in trackRunStart..<trackRunEnd {
            let sampleDurationValue = try checkNonNegative(
                value: sampleDurationsPresent ? CMTimeValue(trun.readInt(as: UInt32.self)) : defaultSampleValues.durationTimeValue
            )
            let sampleSize = try checkNonNegative(
                value: sampleSizesPresent ? Int(trun.readInt(as: UInt32.self)) : defaultSampleValues.size
            )
            let sampleFlags = try checkNonNegative(
                value: sampleFlagsPresent
                ? Int(trun.readInt(as: UInt32.self))
                : (sampleIndex == 0 && firstSampleFlagsPresent) ? firstSampleFlags : defaultSampleValues.flags
            )

            var sampleCompositionTimeOffset: CMTimeValue = 0
            if sampleCompositionTimeOffsetsPresent {
                // The BMFF spec (ISO 14496-12) states that sample offsets should be unsigned integers in
                // version 0 trun boxes, however a significant number of streams violate the spec and use
                // signed integers instead. It's safe to always decode sample offsets as signed integers
                // here, because unsigned integers will still be parsed correctly (unless their top bit is
                // set, which is never true in practice because sample offsets are always small).
                sampleCompositionTimeOffset = try CMTimeValue(trun.readInt(as: Int32.self))
            }

            let decodeTimeValue = cumulativeTime + timelineOffset

            sampleDecodeTimes[sampleIndex] = CMTime(value: decodeTimeValue, timescale: timescale)
            samplePresentationTimes[sampleIndex] = CMTime(
                value: decodeTimeValue + sampleCompositionTimeOffset,
                timescale: timescale
            )
            sampleDurations[sampleIndex] = CMTime(value: sampleDurationValue, timescale: timescale)

            sampleSizeTable[sampleIndex] = sampleSize
            sampleIsSyncFrameTable[sampleIndex] = ((sampleFlags >> 16) & 0x1) == 0 && (!workaroundEveryVideoFrameIsSyncFrame || sampleIndex == 0)
            cumulativeTime += sampleDurationValue
        }

        fragment.sampleSizeTable = sampleSizeTable
        fragment.sampleDecodeTimes = sampleDecodeTimes
        fragment.samplePresentationTimes = samplePresentationTimes
        fragment.sampleDurations = sampleDurations
        fragment.sampleIsSyncFrameTable = sampleIsSyncFrameTable
        fragment.nextFragmentDecodeTime = cumulativeTime
        return trackRunEnd
    }

    private func checkNonNegative<T: FixedWidthInteger>(value: T) throws -> T {
        if value < 0 {
            throw ParserError.createForMalformedContainer(
                message: "Unexpected negative value: \(value)"
            )
        }

        return value
    }

    private func parseUUID(
        uuid: inout BlockBufferReader,
        out: inout TrackFragment,
    ) throws {
        uuid.moveReaderIndex(to: MP4Box.boxSize)
        let boxArray = try uuid.readBytes(length: 16)
        let piffSampleEncryptionBoxExtendedType: [UInt8] = [
            0xA2, 0x39, 0x4F, 0x52, 0x5A, 0x9B, 0x4F, 0x14,
            0xA2, 0x44, 0x6C, 0x42, 0x7C, 0x64, 0x8D, 0xF4,
        ]

        // Currently this parser only supports Microsoft's PIFF SampleEncryptionBox.
        guard piffSampleEncryptionBoxExtendedType == boxArray else {
            return
        }

        try parseSenc(senc: &uuid, offset: 16, out: &out)
    }

    private func parseSenc(
        senc: inout BlockBufferReader,
        offset: Int = 0,
        out: inout TrackFragment
    ) throws {
        fatalError()
    }

    private func parseSampleGroups(
        traf: ContainerBox,
        schemeType: String?,
        out: inout TrackFragment
    ) throws {
        //fatalError()
        // TODO: parseSampleGroups
    }

    private func parseSidx(atom: inout BlockBufferReader, inputPosition: Int) throws -> (CMTime, ChunkIndex) {
        atom.moveReaderIndex(to: MP4Box.headerSize)
        let (version, _) = try BoxParser.readFullboxExtra(reader: &atom)
        atom.moveReaderIndex(forwardBy: 4)

        let timescale = try CMTimeScale(atom.readInt(as: UInt32.self))
        let earliestPtsValue: CMTimeValue
        var offset = inputPosition

        if version == 0 {
            earliestPtsValue = try CMTimeValue(atom.readInt(as: UInt32.self))
            offset += try Int(atom.readInt(as: UInt32.self))
        } else {
            earliestPtsValue = try CMTimeValue(atom.readInt(as: UInt64.self))
            offset += try Int(atom.readInt(as: UInt64.self))
        }

        let earliestPresentationTime = CMTime(
            value: earliestPtsValue,
            timescale: timescale
        )

        atom.moveReaderIndex(forwardBy: 2)
        let referenceCount = try Int(atom.readInt(as: UInt16.self))

        var sizes = Array<Int>(repeating: 0, count: referenceCount)
        var offsets = Array<Int>(repeating: 0, count: referenceCount)
        var durations = Array<CMTime>(repeating: .zero, count: referenceCount)
        var times = Array<CMTime>(repeating: .zero, count: referenceCount)

        // Accumulate in the sidx's own timescale. Every CMTime below is built from this
        // accumulator with the same timescale, so times[i] + durations[i] == times[i + 1]
        // holds exactly — no rounding to compensate for.
        var timeValue = earliestPtsValue

        for index in 0..<referenceCount {
            let firstInt = try atom.readInt(as: UInt32.self)
            guard firstInt & 0x8000_0000 == 0 else {
                throw ParserError.createForMalformedContainer(message: "Unhandled indirect reference")
            }

            let referenceDuration = try CMTimeValue(atom.readInt(as: UInt32.self))
            sizes[index] = Int(firstInt & 0x7FFF_FFFF)
            offsets[index] = offset

            times[index] = CMTime(value: timeValue, timescale: timescale)
            durations[index] = CMTime(value: referenceDuration, timescale: timescale)

            timeValue += referenceDuration

            atom.moveReaderIndex(forwardBy: 4)  // SAP word
            offset += sizes[index]
        }

        return (
            earliestPresentationTime,
            ChunkIndex(
                sizes: sizes,
                offsets: offsets,
                durations: durations,
                times: times
            )
        )
    }

    private func readEncryptionData(input: ExtractorInput, _ isolation: isolated any Actor) async throws {
        var nextTrackBundle: TrackBundle?
        var nextDataOffset = Int.max
        for trackBundle in trackBundles.values {
            let trackFragment = trackBundle.fragment
            // TODO:
//            if trackFragment.sampleEncryptionDataNeedsFill,
//               trackFragment.auxiliaryDataPosition < nextDataOffset {
//                nextDataOffset = trackFragment.auxiliaryDataPosition
//                nextTrackBundle = trackBundle
//            }
        }

        guard let nextTrackBundle else {
            parserState = .readingSampleStart
            return
        }

        fatalError()
        let bytesToSkip = nextDataOffset - input.getPosition(isolation)
        if bytesToSkip < 0 {
            throw ParserError.createForMalformedContainer(
                message: "Offset to encryption data was negative."
            )
        }

        try input.skip(length: bytesToSkip, isolation)
        // TODO: nextTrackBundle.fragment.fillEncryptionData(input)
    }

    private func readSample(input: ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        var trackBundle = currentTrackBundle
        if trackBundle == nil {
            guard let unwrappedTrackBundle = nextTrackBundle(from: trackBundles.values.elements) else {
                // We've run out of samples in the current mdat. Discard any trailing data and prepare to
                // read the header of the next atom.
                let bytesToSkip = endOfMdatPosition - input.getPosition(isolation)
                if bytesToSkip < 0 {
                    throw ParserError.createForMalformedContainer(
                        message: "Offset to end of mdat was negative."
                    )
                }
                try input.skip(length: bytesToSkip, isolation)
                enterReadingAtomHeaderState()
                return false
            }
            trackBundle = unwrappedTrackBundle

            let nextDataPosition = unwrappedTrackBundle.getCurrentSampleOffset()
            var bytesToSkip = nextDataPosition - input.getPosition(isolation)
            if bytesToSkip < 0 {
                // TODO: log "Ignoring negative offset to sample data."
                bytesToSkip = 0
            }

            try input.skip(length: bytesToSkip, isolation)
            currentTrackBundle = unwrappedTrackBundle
        }

        guard let trackBundle else { return false }

        if parserState == .readingSampleStart {
            sampleSize = trackBundle.getCurrentSampleSize()
            isSampleDependedOn = !canReadWithinGopSampleDependencies(
                format: trackBundle.moovSampleTable.track.format
            )

            if trackBundle.currentSampleIndex < trackBundle.firstSampleToOutputIndex {
                try input.skip(length: sampleSize, isolation)
                // TODO: trackBundle.skipSampleEncryptionData()
                if !trackBundle.next() {
                    currentTrackBundle = nil
                }
                parserState = .readingSampleStart
                return true
            }

            // TODO: Track.TRANSFORMATION_CEA608_CDAT
//            if trackBundle.moovSampleTable.track

            if trackBundle.moovSampleTable.track.format.sampleMimeType == .audioAC4 {
                // TODO: AC4 samples need to be prefixed with a clear sample header.
            } else {
                sampleBytesWritten = trackBundle.outputSampleEncryptionData(
                    sampleSize: sampleSize,
                    clearHeaderSize: .zero
                )
            }

            sampleSize += sampleBytesWritten
            parserState = .readingSampleContinue
            sampleCurrentNalBytesRemaining = 0
        }

//        let track = trackBundle.moovSampleTable.track
        let output = trackBundle.output
        let sampleTimingInfo = trackBundle.getCurrentSampleTimingInfo()
//        if let timestampAdjuster {
            // TODO: sampleTime = timestampAdjuster.adjustSampleTimestamp
//        }

        // TODO: nalUnitRead

        let buffer = try await input.readFully(length: sampleSize - sampleBytesWritten, isolation)
        if buffer.dataLength == 0 {
            print()
        }
        try! await output.sampleData(data: buffer, isolation: output.isolation)

        var sampleFlags = trackBundle.getCurrentSampleFlags()
        if !isSampleDependedOn {
            sampleFlags.insert(.notDependedOn)
        }

        // TODO: cryptoData

        try await output.sampleMetadata(
            time: sampleTimingInfo,
            flags: sampleFlags,
            range: 0..<sampleSize,
            isolation: output.isolation
        )

        // After we have the sampleTimingInfo, we can commit all the pending metadata samples
        outputPendingMetadataSamples(sampleTiming: sampleTimingInfo)
        if !trackBundle.next() {
            currentTrackBundle = nil
        }
        parserState = .readingSampleStart
        return true
    }

    private func canReadWithinGopSampleDependencies(format: Format) -> Bool {
        switch format.sampleMimeType {
        case .videoH264:
            return flags.contains(.readWithinGopSampleDependencies)
        case .videoH265:
            return flags.contains(.readWithinGopSampleDependenciesH265)
        default:
            return false
        }
    }

    private func outputPendingMetadataSamples(sampleTiming: CMSampleTimingInfo) {
        // TODO: outputPendingMetadataSamples
    }

    private func nextTrackBundle(from trackBundles: [TrackBundle]) -> TrackBundle? {
        trackBundles
            .filter(\.hasRemainingSamples)
            .min { $0.getCurrentSampleOffset() < $1.getCurrentSampleOffset() }
    }

    private func drmInitDataFromAtoms(leafChildren: [LeafBox]) {
        fatalError()
    }
}

public extension FragmentedMp4Extractor {
    struct Flags: OptionSet {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let workaroundEveryVideoFrameIsSyncFrame = Flags(rawValue: 1)
        public static let workaroundIgnoreTfdtBox = Flags(rawValue: 1 << 1)
        public static let enableEmsgTrack = Flags(rawValue: 1 << 2)
        public static let workaroundIgnoreEditLists = Flags(rawValue: 1 << 3)
        public static let emitRawSubtitleData = Flags(rawValue: 1 << 4)
        public static let readWithinGopSampleDependencies = Flags(rawValue: 1 << 5)
        public static let readWithinGopSampleDependenciesH265 = Flags(rawValue: 1 << 6)
        public static let mergeFragmentedSidx = Flags(rawValue: 1 << 7)
    }
}

private extension FragmentedMp4Extractor {
    func shouldParseContainerAtom(atom: UInt32) -> Bool {
        let atoms: [MP4Box.BoxType] = [.moov, .trak, .mdia, .minf, .stbl, .moof, .traf, .mvex, .edts, .meta]
        return atoms.contains(where: { $0.rawValue == atom })
    }

    func shouldParseLeafAtom(atom: UInt32) -> Bool {
        let atoms: [MP4Box.BoxType] = [
            .hdlr, .mdhd, .mvhd, .sidx, .stsd, .stts, .ctts, .stsc, .stsz, .stz2, .stco, .co64, .stss, .tfdt, .tfhd, .tkhd, .trex, .trun, .pssh, .saiz, .saio, .senc, .uuid, .sbgp, .sgpd, .elst, .mehd, .emsg
        ]
        return atoms.contains(where: { $0.rawValue == atom })
    }
}

private extension FragmentedMp4Extractor {
    enum State {
        case readingAtomHeader
        case readingAtomPayload
        case readingEncryptionData
        case readingSampleStart
        case readingSampleContinue
    }

    final class TrackBundle {
        let output: TrackOutput
        let baseFormat: Format
        var fragment: TrackFragment
        var moovSampleTable: TrackSampleTable
        var defaultSampleValues: DefaultSampleValues

        var currentSampleIndex: Int = 0
        var currentSampleInTrackRun: Int = 0
        var currentTrackRunIndex: Int = 0
        var firstSampleToOutputIndex: Int = 0

        var currentlyInFragment: Bool = false

        var hasRemainingSamples: Bool {
            currentlyInFragment
                ? currentTrackRunIndex < fragment.trunCount
                : currentSampleIndex < moovSampleTable.sampleCount
        }

        init(
            output: TrackOutput,
            moovSampleTable: TrackSampleTable,
            defaultSampleValues: DefaultSampleValues,
            baseFormat: Format,
            _ isolation: isolated any Actor
        ) async throws {
            self.output = output
            self.moovSampleTable = moovSampleTable
            self.defaultSampleValues = defaultSampleValues
            self.baseFormat = baseFormat
            fragment = TrackFragment()

            try await reset(moovSampleTable: moovSampleTable, defaultSampleValues: defaultSampleValues, isolation)
        }

        func reset(
            moovSampleTable: TrackSampleTable,
            defaultSampleValues: DefaultSampleValues,
            _ isolation: isolated any Actor
        ) async throws {
            self.moovSampleTable = moovSampleTable
            self.defaultSampleValues = defaultSampleValues
            try await output.setFormat(baseFormat, isolation: output.isolation)
            resetFragmentInfo()
        }

        func resetFragmentInfo() {
            fragment.reset()
            currentSampleIndex = 0
            currentSampleInTrackRun = 0
            currentTrackRunIndex = 0
            firstSampleToOutputIndex = 0
            currentlyInFragment = false
        }

        func seek(to time: CMTime) {
            var searchIndex = currentSampleIndex
            while searchIndex < fragment.sampleCount,
                  fragment.samplePresentationTimes[searchIndex] <= time {
                if fragment.sampleIsSyncFrameTable[searchIndex] {
                    firstSampleToOutputIndex = searchIndex
                }
                searchIndex += 1
            }
        }

        func getCurrentSampleTimingInfo() -> CMSampleTimingInfo {
            if !currentlyInFragment {
                moovSampleTable.timingInfo(at: currentSampleIndex)
            } else {
                fragment.timingInfo(at: currentSampleIndex)
            }
        }

        func getCurrentSampleOffset() -> Int {
            if !currentlyInFragment {
                moovSampleTable.offsets[currentSampleIndex]
            } else {
                fragment.trunDataPosition[currentTrackRunIndex]
            }
        }

        func getCurrentSampleSize() -> Int {
            if !currentlyInFragment {
                moovSampleTable.sizes[currentSampleIndex]
            } else {
                fragment.sampleSizeTable[currentSampleIndex]
            }
        }

        func getCurrentSampleFlags() -> SampleFlags {
            if !currentlyInFragment {
                moovSampleTable.flags[currentSampleIndex]
            } else {
                fragment.sampleIsSyncFrameTable[currentSampleIndex] ? .keyframe : []
            }
        }

        func next() -> Bool {
            currentSampleIndex += 1
            guard currentlyInFragment else { return false }

            currentSampleInTrackRun += 1
            if currentSampleInTrackRun == fragment.trunLength[currentTrackRunIndex] {
                currentTrackRunIndex += 1
                currentSampleInTrackRun = 0
                return false
            }

            return true
        }

        func outputSampleEncryptionData(sampleSize: Int, clearHeaderSize: Int) -> Int {
            // TODO: outputSampleEncryptionData
            return .zero
        }
    }

    private func checkAtomArgument(
        _ check: @autoclosure () -> Bool,
        message: String
    ) throws {
        if check() == false {
            let cause: Error? = if let boxType = atomType {
                BoxParser.BoxParserErrors.badBoxContent(type: boxType, reason: nil)
            } else {
                nil
            }

            throw ParserError
                .createForUnsupportedContainerFeature(message: message, cause: cause)
        }
    }
}

//#endif
