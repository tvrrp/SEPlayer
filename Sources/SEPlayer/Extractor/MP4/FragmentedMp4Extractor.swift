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

    private var lastSniffFailures = [SniffFailure]()
    private var parserState: State = .readingAtomHeader

    private var trackBundles: [TrackBundle] = []

    private var atomHeader: ByteBuffer
    private var atomHeaderBytesRead: Int = 0
    private var atomSize: UInt64 = 0
    private var atomType: UInt32 = 0

    private var atomData: ByteBuffer?
    private var seenFtypAtom: Bool = false
    private var containerAtoms: [ContainerBox] = []

    private var durationUs = Int64.timeUnset


    private var haveOutputSeekMap = false

    init(
        queue: Queue,
        extractorOutput: ExtractorOutput,
        flags: Flags = []
    ) {
        self.queue = queue
        self.extractorOutput = extractorOutput
        self.atomHeader = ByteBuffer()
        self.flags = flags
    }

    public func shiff(input: ExtractorInput) throws -> Bool {
        let result = try Sniffer().sniffFragmented(input: input)
        lastSniffFailures = [result].compactMap { $0 }
        return result == nil
    }

    public func getSniffFailureDetails() -> [SniffFailure] { lastSniffFailures }

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

        let atomPosition = input.getPosition() - atomHeaderBytesRead
        if atomType == MP4Box.BoxType.moof.rawValue || atomType == MP4Box.BoxType.mdat.rawValue {
            if !haveOutputSeekMap {
                extractorOutput.seekMap(seekMap: Unseekable(durationUs: durationUs, startPosition: atomPosition))
                haveOutputSeekMap = true
            }
        }

        if atomType == MP4Box.BoxType.moof.rawValue {
            for index in 0..<trackBundles.count {
                trackBundles[index].fragment.atomPosition = atomPosition
                trackBundles[index].fragment.auxiliaryDataPosition = atomPosition
                trackBundles[index].fragment.dataPosition = atomPosition
            }
        }

        fatalError()
    }
    
    private func readAtomPayload(input: ExtractorInput) throws {
        
    }
    
    private func processAtomEnded(atomEndPosition: Int) throws {
        
    }
    
    private func onLeafAtomRead(leaf: LeafBox, inputPosition: Int) throws {
        
    }
    
    private func onContainerAtomRead(container: ContainerBox, inputPosition: Int) throws {
        
    }
    
    private func onMoovContainerAtomRead(moov: ContainerBox) throws {
        
    }
    
    private func getDefaultSampleValues(
        defaultSampleValues: [(Int, DefaultSampleValues)],
        trackId: Int
    ) throws -> DefaultSampleValues {
        if defaultSampleValues.count == 1 {
            return defaultSampleValues[0].1
        }
        
        if let result = defaultSampleValues.first(where: { $0.0 == trackId }) {
            return result.1
        } else {
            fatalError() // TODO: throw error
        }
    }
    
    private func onMoofContainerAtomRead(moof: ContainerBox) throws {
        
    }
    
    private func initExtraTracks() {
        
    }
    
    private func onEmsgLeafAtomRead(atom: ByteBuffer) throws {
        
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
    
    private func parseMehd(mehd: inout ByteBuffer) throws -> Int {
        mehd.moveReaderIndex(to: MP4Box.headerSize)
        let fullAtom = try Int(mehd.readInt(as: UInt32.self))
        let version = try BoxParser.readFullboxVersionNoFlags(reader: &mehd)
        return try version == 0 ? Int(mehd.readInt(as: UInt32.self)) : Int(mehd.readInt(as: UInt64.self))
    }
    
    private func parseMoof(
        moof: ContainerBox,
        trackBundles: [TrackBundle],
        haveSideloadedTrack: Bool,
        flags: Flags
    ) throws {
        
    }
    
    private func parseTraf(
        traf: ContainerBox,
        trackBundles: [TrackBundle],
        haveSideloadedTrack: Bool,
        flags: Flags
    ) throws {
        
    }
    
    private func parseTruns(
        traf: ContainerBox,
        trackBundle: TrackBundle,
        flags: Flags
    ) throws {
        
    }
    
    private func parseSaio(saio: inout ByteBuffer, out: inout TrackFragment) throws {
        
    }
    
    private func parseTfhd(
        tfhd: inout ByteBuffer,
        trackBundles: [TrackBundle],
        haveSideloadedTrack: Bool
    ) throws -> TrackBundle {
        fatalError()
    }
    
    private func parseTfdt(tfdt: inout ByteBuffer) throws {
        
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
        
    }
    
    private func parseSidx(atom: inout ByteBuffer, inputPosition: Int) throws -> (Int, ChunkIndex) {
        fatalError()
    }

    private func readSample(input: ExtractorInput) throws -> Bool {
        fatalError()
    }

    private func outputPendingMetadataSamples(sampleTimeUs: Int64) {
        
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
    enum State {
        case readingAtomHeader
        case readingAtomPayload
        case readingSampleStart
        case readingSampleContinue
    }

    struct TrackBundle {
        let output: TrackOutput
        var fragment: TrackFragment
        let moovSampleTable: BoxParser.TrackSampleTable
        
    }
}

private extension Track {
    var isEdtsListDurationForEntireMediaTimeline: Bool {
        fatalError()
    }
}
