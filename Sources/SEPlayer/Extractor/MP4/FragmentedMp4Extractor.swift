//
//  FragmentedMp4Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.06.2025.
//

public final class FragmentedMp4Extractor: Extractor {
    private let queue: Queue
    private let extractorOutput: ExtractorOutput
    private let boxParser = BoxParser()
    private let flags: Flags

    private var sideloadedTrack: Track?
    private var trackBundles: [Int: TrackBundle] = [:]


    private var atomHeader: ByteBuffer
    private var containerAtoms: [ContainerBox] = []

    private var parserState: State = .readingAtomHeader
    private var atomType: UInt32 = 0
    private var atomSize: UInt64 = 0
    private var atomHeaderBytesRead: Int = 0
    private var atomData: ByteBuffer?
    private var endOfMdatPosition: Int = 0
    private var pendingMetadataSampleBytes: Int = 0
    private var pendingSeekTimeUs = Int64.timeUnset
    private var seenFtypAtom: Bool = false

    private var durationUs = Int64.timeUnset
    private var segmentIndexEarliestPresentationTimeUs = Int64.timeUnset
    private var currentTrackBundle: TrackBundle?
    private var sampleSize: Int = 0
    private var sampleBytesWritten: Int = 0
    private var isSampleDependedOn = false

    private var haveOutputSeekMap = false

    init(
        queue: Queue,
        extractorOutput: ExtractorOutput,
        flags: Flags = []
    ) {
        self.queue = queue
        self.extractorOutput = extractorOutput
        self.atomHeader = ByteBufferAllocator().buffer(capacity: MP4Box.fullHeaderSize)
        self.flags = flags
    }

    public func shiff(input: ExtractorInput) throws {
        assert(queue.isCurrent())
        if let result = try Sniffer().sniffFragmented(input: input) {
            throw result
        }
    }

    public func seek(to position: Int, timeUs: Int64) {
        assert(queue.isCurrent())
    }

    public func read(input: ExtractorInput) throws -> ExtractorReadResult {
        assert(queue.isCurrent())
        while true {
            switch parserState {
            case .readingAtomHeader:
                if try !readAtomHeader(input: input) {
                    return .endOfInput
                }
            case .readingAtomPayload:
                try readAtomPayload(input: input)
            default:
                if try readSample(input: input) {
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

    private func readAtomHeader(input: ExtractorInput) throws -> Bool {
        assert(queue.isCurrent())
        if atomHeaderBytesRead == 0 {
            if try !input.readFully(to: &atomHeader, offset: 0, length: MP4Box.headerSize, allowEndOfInput: true) {
                return false
            }

            atomHeaderBytesRead = MP4Box.headerSize
            atomHeader.moveReaderIndex(to: .zero)
            atomSize = try UInt64(atomHeader.readInt(as: UInt32.self))
            atomType = try atomHeader.readInt(as: UInt32.self)
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

        let atomPosition = input.getPosition() - atomHeaderBytesRead
        if atomType == MP4Box.BoxType.moof.rawValue || atomType == MP4Box.BoxType.mdat.rawValue {
            if !haveOutputSeekMap {
                extractorOutput.seekMap(seekMap: Unseekable(durationUs: durationUs, startPosition: atomPosition))
                haveOutputSeekMap = true
            }
        }

        if atomType == MP4Box.BoxType.moof.rawValue {
            for trackBundle in trackBundles.values {
                let fragment = trackBundle.fragment
                fragment.atomPosition = atomPosition
                fragment.auxiliaryDataPosition = atomPosition
                fragment.dataPosition = atomPosition
            }
        }

        if atomType == MP4Box.BoxType.mdat.rawValue {
            currentTrackBundle = nil
            endOfMdatPosition = atomPosition + Int(atomSize)
            parserState = .readingEncryptionData
            return true
        }

        if MP4Box.BoxType(rawValue: atomType) == nil {
            print()
        }

        if shouldParseContainerAtom(atom: atomType) {
            let endPosition = input.getPosition() + Int(atomSize) - MP4Box.headerSize
            containerAtoms.append(ContainerBox(type: atomType, endPosition: endPosition))
            if atomSize == atomHeaderBytesRead {
                try processAtomEnded(atomEndPosition: endPosition)
            } else {
                // Start reading the first child atom.
                enterReadingAtomHeaderState()
            }
        } else if shouldParseLeafAtom(atom: atomType) {
            guard atomHeaderBytesRead == MP4Box.headerSize else {
                throw ParserException(
                    unsupportedContainerFeature: "Leaf atom defines extended atom size (unsupported)."
                )
            }

            guard atomSize < .max else {
                throw ParserException(
                    unsupportedContainerFeature: "Skipping atom with size > \(Int.max) (unsupported)."
                )
            }

            atomHeader.moveReaderIndex(to: 0)
            atomData = ByteBufferAllocator().buffer(buffer: atomHeader)
            parserState = .readingAtomPayload
        } else {
            guard atomSize < .max else {
                throw ParserException(
                    unsupportedContainerFeature: "Skipping atom with size > \(Int.max) (unsupported)."
                )
            }

            atomData = nil
            parserState = .readingAtomPayload
        }

        return true
    }

    private func readAtomPayload(input: ExtractorInput) throws {
        let atomPayloadSize = Int(atomSize) - atomHeaderBytesRead
        let atomEndPosition = input.getPosition() + atomPayloadSize

        if var atomData {
            try input.readFully(to: &atomData, offset: MP4Box.headerSize, length: atomPayloadSize)
            try onLeafAtomRead(leaf: LeafBox(type: atomType, data: atomData), inputPosition: input.getPosition())
        } else {
            try input.skipFully(length: atomEndPosition)
        }

        try processAtomEnded(atomEndPosition: input.getPosition())
    }

    private func processAtomEnded(atomEndPosition: Int) throws {
        while !containerAtoms.isEmpty, containerAtoms.first?.endPosition == atomEndPosition {
            try onContainerAtomRead(container: containerAtoms.removeFirst())
        }
        enterReadingAtomHeaderState()
    }

    private func onLeafAtomRead(leaf: LeafBox, inputPosition: Int) throws {
        if !containerAtoms.isEmpty {
            containerAtoms[0].add(leaf)
        } else if leaf.type == .sidx {
            var data = leaf.data
            let (timeUs, chunkIndex) = try parseSidx(atom: &data, inputPosition: inputPosition)
            segmentIndexEarliestPresentationTimeUs = timeUs
            extractorOutput.seekMap(seekMap: chunkIndex)
            haveOutputSeekMap = true
        } else if leaf.type == .emsg {
            try onEmsgLeafAtomRead(atom: leaf.data)
        }
    }

    private func onContainerAtomRead(container: ContainerBox) throws {
        if container.type == .moov {
            try onMoovContainerAtomRead(moov: container)
        } else if container.type == .moof {
            try onMoofContainerAtomRead(moof: container)
        } else if !containerAtoms.isEmpty {
            containerAtoms[0].add(container)
        }
    }

    private func onMoovContainerAtomRead(moov: ContainerBox) throws {
        guard sideloadedTrack == nil else {
            throw ParserException(malformedContainer: "Unexpected moov box.")
        }

        let mvex = try moov.getContainerBoxOfType(type: .mvex)
            .checkNotNil(BoxParser.BoxParserErrors.missingBox(type: .mvex))
        var defaultSampleValuesArray = [Int: DefaultSampleValues]()
        var duration = Int64.timeUnset

        for leafChild in moov.leafChildren {
            if leafChild.type == .trex {
                var trex = leafChild.data
                let (trackId, defaultSampleValues) = try parseTrex(trex: &trex)
                defaultSampleValuesArray[trackId] = defaultSampleValues
            } else if leafChild.type == .mehd {
                var mehd = leafChild.data
                duration = try parseMehd(mehd: &mehd)
            }
        }

        var gaplessInfoHolder = GaplessInfoHolder()
        let sampleTables = try boxParser.parseTraks(
            moov: moov,
            gaplessInfoHolder: &gaplessInfoHolder,
            duration: duration,
            ignoreEditLists: flags.contains(.workaroundIgnoreEditLists),
            isQuickTime: false
        )

        if trackBundles.isEmpty {
            for sampleTable in sampleTables {
                let track = sampleTable.track
                let output = extractorOutput.track(for: track.id, trackType: track.type)
                let trackBundle = TrackBundle(
                    output: output,
                    moovSampleTable: sampleTable,
                    defaultSampleValues: try getDefaultSampleValues(
                        defaultSampleValues: defaultSampleValuesArray,
                        trackId: track.id
                    )
                )

                trackBundles[track.id] = trackBundle
                durationUs = max(durationUs, track.durationUs)
            }

            extractorOutput.endTracks()
        } else {
            assert(trackBundles.count == sampleTables.count)
            for sampleTable in sampleTables {
                let track = sampleTable.track
                trackBundles[track.id]?.reset(
                    moovSampleTable: sampleTable,
                    defaultSampleValues: try getDefaultSampleValues(
                        defaultSampleValues: defaultSampleValuesArray,
                        trackId: track.id
                    )
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

        if pendingSeekTimeUs != .timeUnset {
            trackBundles.values.forEach { $0.seet(to: pendingSeekTimeUs) }
            pendingSeekTimeUs = .timeUnset
        }
    }
    
    private func initExtraTracks() {
        fatalError()
    }
    
    private func onEmsgLeafAtomRead(atom: ByteBuffer) throws {
        fatalError()
    }
    
    private func parseTrex(trex: inout ByteBuffer) throws -> (Int, DefaultSampleValues) {
        trex.moveReaderIndex(to: MP4Box.fullHeaderSize)
        let trackId = try Int(trex.readInt(as: UInt32.self))
        let defaultSampleDescriptionIndex = try Int(trex.readInt(as: UInt32.self)) - 1
        let defaultSampleDuration = try Int(trex.readInt(as: UInt32.self))
        let defaultSampleSize = try Int(trex.readInt(as: UInt32.self))
        let defaultSampleFlags = try Int(trex.readInt(as: UInt32.self))

        return (trackId, DefaultSampleValues(
            sampleDescriptionIndex: defaultSampleDescriptionIndex,
            duration: defaultSampleDuration,
            size: defaultSampleSize,
            flags: defaultSampleFlags
        ))
    }
    
    private func parseMehd(mehd: inout ByteBuffer) throws -> Int64 {
        mehd.moveReaderIndex(to: MP4Box.headerSize)
        let fullAtom = try Int(mehd.readInt(as: UInt32.self))
        let version = try BoxParser.readFullboxVersionNoFlags(reader: &mehd)
        return try version == 0 ? Int64(mehd.readInt(as: UInt32.self)) : Int64(mehd.readInt(as: UInt64.self))
    }
    
    private func parseMoof(
        moof: ContainerBox,
        trackBundles: [Int: TrackBundle],
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
        trackBundles: [Int: TrackBundle],
        haveSideloadedTrack: Bool,
        flags: Flags
    ) throws {
        fatalError()
    }

    private func parseTruns(
        traf: ContainerBox,
        trackBundle: TrackBundle,
        flags: Flags
    ) throws {
        var trunCount = 0
        var totalSampleCount = 0

        for leafChild in traf.leafChildren {
            if leafChild.type == .trun {
                fatalError()
            }
        }
    }

    private func parseSaio(saio: inout ByteBuffer, out: inout TrackFragment) throws {
        fatalError()
    }

    private func parseTfhd(
        tfhd: inout ByteBuffer,
        trackBundles: [TrackBundle],
        haveSideloadedTrack: Bool
    ) throws -> TrackBundle {
        fatalError()
    }
    
    private func parseTfdt(tfdt: inout ByteBuffer) throws {
        fatalError()
    }
    
    private func parseTrun(
        trackBundle: TrackBundle,
        index: Int,
        flags: Flags,
        trun: inout ByteBuffer,
        trackRunStart: Int
    ) throws -> Int {
        fatalError()
    }
    
    private func checkNonNegative(_ value: Int) throws -> Int {
        guard value > 0 else {
            throw ParserException(malformedContainer: "Unexpected negative value: \(value)")
        }
        
        return value
    }
    
    private func parseSampleGroups(
        traf: ContainerBox,
        schemeType: String?,
        out: inout TrackFragment
    ) throws {
        fatalError()
    }
    
    private func parseSidx(atom: inout ByteBuffer, inputPosition: Int) throws -> (Int64, ChunkIndex) {
        fatalError()
    }

    private func readSample(input: ExtractorInput) throws -> Bool {
        fatalError()
    }

    private func outputPendingMetadataSamples(sampleTimeUs: Int64) {
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
    }
}

private extension FragmentedMp4Extractor {
    func shouldParseContainerAtom(atom: UInt32) -> Bool {
        let atoms: [MP4Box.BoxType] = [.moov, .trak, .mdia, .minf, .stbl, .moof, .traf, .mvex, .edts]
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
        var fragment: TrackFragment
        var moovSampleTable: BoxParser.TrackSampleTable
        var defaultSampleValues: DefaultSampleValues

        var currentSampleIndex: Int = 0
        var currentSampleInTrackRun: Int = 0
        var currentTrackRunIndex: Int = 0
        var firstSampleToOutputIndex: Int = 0

        var currentlyInFragment: Bool = false

        init(
            output: TrackOutput,
            moovSampleTable: BoxParser.TrackSampleTable,
            defaultSampleValues: DefaultSampleValues,
        ) {
            self.output = output
            self.moovSampleTable = moovSampleTable
            self.defaultSampleValues = defaultSampleValues
            fragment = TrackFragment()

            reset(moovSampleTable: moovSampleTable, defaultSampleValues: defaultSampleValues)
        }

        func reset(
            moovSampleTable: BoxParser.TrackSampleTable,
            defaultSampleValues: DefaultSampleValues
        ) {
            self.moovSampleTable = moovSampleTable
            self.defaultSampleValues = defaultSampleValues
            output.setFormat(moovSampleTable.track.format)
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

        func seet(to timeUs: Int64) {
            var searchIndex = currentSampleIndex
            while searchIndex < fragment.sampleCount,
                  fragment.samplePresentationTimesUs[searchIndex] <= timeUs {
                if fragment.sampleIsSyncFrameTable[searchIndex] {
                    firstSampleToOutputIndex = searchIndex
                }
                searchIndex += 1
            }
        }

        func getCurrentSamplePresentationTimeUs() -> Int64 {
            if !currentlyInFragment {
                moovSampleTable.samples[currentSampleIndex].presentationTimeStampUs
            } else {
                fragment.samplePresentationTimesUs[currentSampleIndex]
            }
        }

        func getCurrentSampleOffset() -> Int {
            if !currentlyInFragment {
                moovSampleTable.samples[currentSampleIndex].offset
            } else {
                fragment.trunDataPosition[currentSampleIndex]
            }
        }

        func getCurrentSampleSize() -> Int {
            if !currentlyInFragment {
                moovSampleTable.samples[currentSampleIndex].size
            } else {
                fragment.sampleSizeTable[currentSampleIndex]
            }
        }

        func getCurrentSampleFlags() -> SampleFlags {
            if !currentlyInFragment {
                moovSampleTable.samples[currentSampleIndex].flags
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
    }
}

private extension Track {
    var isEdtsListDurationForEntireMediaTimeline: Bool {
        fatalError()
    }
}
