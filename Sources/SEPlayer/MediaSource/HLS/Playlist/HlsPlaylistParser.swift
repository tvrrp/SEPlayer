//
//  HlsPlaylistParser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.08.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// A parsed HLS playlist: multivariant or media.
public enum HlsParsedPlaylist {
    case multivariant(HlsMultivariantPlaylist)
    case media(HlsMediaPlaylist)

    public var playlist: any HlsPlaylist {
        switch self {
        case let .multivariant(playlist): playlist
        case let .media(playlist): playlist
        }
    }
}

/// HLS playlists parsing logic.
///
/// Parses variants and renditions, segments with byte ranges, initialization sections, AES-128 encryption,
/// discontinuities and variable substitution, and what low-latency streams add: parts, preload hints, rendition
/// reports and delta updates, which take the segments they skip from the previous playlist.
public struct HlsPlaylistParser {
    public enum ParseError: Error {
        /// The input isn't an HLS playlist.
        case notAPlaylist
        /// A required attribute or value is missing or malformed.
        case malformed(String)
        /// A feature of the playlist isn't supported.
        case unsupported(String)
        /// A delta update skips segments the previous playlist doesn't list: only a full playlist can follow it.
        case deltaUpdateUnusable
    }

    /// The multivariant playlist the media playlists belong to: they can import its variables.
    private let multivariantPlaylist: HlsMultivariantPlaylist?
    /// The playlist a delta update updates: it lists the segments the update skips.
    private let previousMediaPlaylist: HlsMediaPlaylist?

    public init(multivariantPlaylist: HlsMultivariantPlaylist? = nil, previousMediaPlaylist: HlsMediaPlaylist? = nil) {
        self.multivariantPlaylist = multivariantPlaylist
        self.previousMediaPlaylist = previousMediaPlaylist
    }

    public func parse(buffer: CMBlockBuffer, url: URL) throws -> HlsParsedPlaylist {
        guard !buffer.isEmpty else { throw ParseError.notAPlaylist }

        let decoded = try buffer.withContiguousStorage { bytes in
            String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
        }
        guard var text = decoded else {
            throw ParseError.notAPlaylist
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let lines = text
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.first?.hasPrefix(Tag.playlistHeader) == true else {
            throw ParseError.notAPlaylist
        }

        for line in lines {
            if line.hasPrefix(Tag.streamInf) {
                return try .multivariant(parseMultivariantPlaylist(lines: lines, url: url))
            } else if Tag.mediaPlaylistTags.contains(where: { line.hasPrefix($0) }) {
                return try .media(parseMediaPlaylist(lines: lines, url: url))
            }
        }
        throw ParseError.notAPlaylist
    }
}

// MARK: - Multivariant playlist

private extension HlsPlaylistParser {
    struct VariantInfo {
        let url: URL
        let attributes: AttributeList
    }

    func parseMultivariantPlaylist(lines: [String], url: URL) throws -> HlsMultivariantPlaylist {
        var variables: [String: String] = [:]
        var tags: [String] = []
        var hasIndependentSegments = false
        var variantInfos: [VariantInfo] = []
        var iFrameVariantInfos: [VariantInfo] = []
        var mediaTags: [AttributeList] = []
        var pendingStreamInf: AttributeList?

        for line in lines {
            if line.hasPrefix("#EXT") { tags.append(line) }

            if line.hasPrefix(Tag.define) {
                let attributes = AttributeList(line, prefix: Tag.define)
                if let name = attributes["NAME"], let value = attributes["VALUE"] {
                    variables[name] = value
                } else if let name = attributes["QUERYPARAM"],
                          let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == name })?.value {
                    variables[name] = value
                }
            } else if line == Tag.independentSegments.rawValue {
                hasIndependentSegments = true
            } else if line.hasPrefix(Tag.media) {
                mediaTags.append(AttributeList(line, prefix: Tag.media))
            } else if line.hasPrefix(Tag.iFrameStreamInf) {
                let attributes = AttributeList(line, prefix: Tag.iFrameStreamInf)
                guard let uri = attributes["URI"].map({ replaceVariableReferences($0, variables: variables) }),
                      let iFrameUrl = URL(string: uri, relativeTo: url)?.absoluteURL else {
                    throw ParseError.malformed("EXT-X-I-FRAME-STREAM-INF without URI")
                }
                iFrameVariantInfos.append(VariantInfo(url: iFrameUrl, attributes: attributes))
            } else if line.hasPrefix(Tag.streamInf) {
                pendingStreamInf = AttributeList(line, prefix: Tag.streamInf)
            } else if !line.hasPrefix("#"), let attributes = pendingStreamInf {
                pendingStreamInf = nil
                let uri = replaceVariableReferences(line, variables: variables)
                guard let variantUrl = URL(string: uri, relativeTo: url)?.absoluteURL else {
                    throw ParseError.malformed("Variant URI \(uri)")
                }
                variantInfos.append(VariantInfo(url: variantUrl, attributes: attributes))
            }
        }

        // The same media playlist may be listed more than once, as for a backup; it stays one variant.
        var variants: [HlsMultivariantPlaylist.Variant] = []
        var seenUrls = Set<URL>()
        for info in variantInfos where seenUrls.insert(info.url).inserted {
            try variants.append(makeVariant(info, index: variants.count, variables: variables))
        }
        var iFrameVariants: [HlsMultivariantPlaylist.Variant] = []
        var seenIFrameUrls = Set<URL>()
        for info in iFrameVariantInfos where seenIFrameUrls.insert(info.url).inserted {
            try iFrameVariants.append(makeVariant(info, index: iFrameVariants.count, variables: variables))
        }
        // Renditions take their codecs from any variant of their group, including those left out as repeats: the
        // same playlist can be listed once for every audio group.
        let allVariants = try variantInfos.enumerated().map { try makeVariant($1, index: $0, variables: variables) }

        var videos: [HlsMultivariantPlaylist.Rendition] = []
        var audios: [HlsMultivariantPlaylist.Rendition] = []
        var subtitles: [HlsMultivariantPlaylist.Rendition] = []
        var closedCaptions: [HlsMultivariantPlaylist.Rendition] = []
        var muxedAudioFormat: AnyFormat?
        var muxedCaptionFormats: [TextFormat]?

        for attributes in mediaTags {
            let value = { (name: String) in
                attributes[name].map { replaceVariableReferences($0, variables: variables) }
            }
            guard let type = value("TYPE"), let groupId = value("GROUP-ID"), let name = value("NAME") else {
                throw ParseError.malformed("EXT-X-MEDIA \(attributes)")
            }
            let renditionUrl = try value("URI").map { uri in
                guard let resolved = URL(string: uri, relativeTo: url)?.absoluteURL else {
                    throw ParseError.malformed("Rendition URI \(uri)")
                }
                return resolved
            }

            func setCommonAttributes<S>(_ format: inout Format<S>) {
                format.id = "\(groupId):\(name)"
                format.label = name
                format.containerMimeType = .applicationM3U8
                format.selectionFlags = selectionFlags(attributes)
                format.roleFlags = roleFlags(attributes)
                format.language = value("LANGUAGE")
            }

            switch type {
            case "VIDEO":
                let variant = allVariants.first { $0.videoGroupId == groupId }
                let codecs = Codecs.ofType(variant?.format.codecs, trackType: .video)
                var videoFormat = VideoFormat()
                setCommonAttributes(&videoFormat)
                videoFormat.codecs = codecs
                videoFormat.codec = Codecs.mediaMimeType(ofType: .video, in: codecs).map(VideoCodec.init)
                if let variant = variant.flatMap({ VideoFormat($0.format) }) {
                    videoFormat.size = variant.size
                    videoFormat.frameRate = variant.frameRate
                }
                // A rendition without a URI is in the variant itself.
                if let renditionUrl {
                    let rendition = HlsMultivariantPlaylist.Rendition(
                        url: renditionUrl,
                        format: AnyFormat(videoFormat),
                        groupId: groupId,
                        name: name,
                        stableRenditionId: value("STABLE-RENDITION-ID")
                    )
                    videos.append(rendition)
                }
            case "AUDIO":
                let variant = allVariants.first { $0.audioGroupId == groupId }
                let codecs = Codecs.ofType(variant?.format.codecs, trackType: .audio)
                var audioFormat = AudioFormat()
                setCommonAttributes(&audioFormat)
                audioFormat.codecs = codecs
                audioFormat.codec = Codecs.mediaMimeType(ofType: .audio, in: codecs).map(AudioCodec.init)
                if let channels = value("CHANNELS")?.split(separator: "/").first, let count = Int(channels) {
                    audioFormat.channelCount = count
                }
                if let sampleRate = value("SAMPLE-RATE").flatMap(Int.init) {
                    audioFormat.sampleRate = sampleRate
                }
                if let renditionUrl {
                    let rendition = HlsMultivariantPlaylist.Rendition(
                        url: renditionUrl,
                        format: AnyFormat(audioFormat),
                        groupId: groupId,
                        name: name,
                        stableRenditionId: value("STABLE-RENDITION-ID")
                    )
                    audios.append(rendition)
                } else if variant != nil {
                    muxedAudioFormat = AnyFormat(audioFormat)
                }
            case "SUBTITLES":
                let variant = allVariants.first { $0.subtitleGroupId == groupId }
                let codecs = Codecs.ofType(variant?.format.codecs, trackType: .text)
                let sampleMimeType = Codecs.mediaMimeType(ofType: .text, in: codecs) ?? .textVTT
                var subtitleFormat = TextFormat()
                setCommonAttributes(&subtitleFormat)
                subtitleFormat.codecs = codecs
                subtitleFormat.codec = TextCodec(sampleMimeType)
                if let renditionUrl {
                    let rendition = HlsMultivariantPlaylist.Rendition(
                        url: renditionUrl,
                        format: AnyFormat(subtitleFormat),
                        groupId: groupId,
                        name: name,
                        stableRenditionId: value("STABLE-RENDITION-ID")
                    )
                    subtitles.append(rendition)
                }
            case "CLOSED-CAPTIONS":
                guard let instreamId = value("INSTREAM-ID") else { continue }
                // CC1 to CC4 are CEA-608 channels; SERVICE1 to SERVICE63 CEA-708 services.
                let isCea608 = instreamId.hasPrefix("CC")
                let channel = Int(instreamId.dropFirst(isCea608 ? 2 : 7))
                var captionFormat = TextFormat()
                setCommonAttributes(&captionFormat)
                captionFormat.codec = if isCea608 {
                    TextCodec(.applicationCEA608, \.cea608) { $0.channel = channel }
                } else {
                    TextCodec(.applicationCEA708, \.cea708) { $0.serviceNumber = channel }
                }
                let rendition = HlsMultivariantPlaylist.Rendition(
                    url: nil,
                    format: AnyFormat(captionFormat),
                    groupId: groupId,
                    name: name,
                    stableRenditionId: value("STABLE-RENDITION-ID")
                )
                closedCaptions.append(rendition)
                muxedCaptionFormats = (muxedCaptionFormats ?? []) + [captionFormat]
            default:
                break
            }
        }

        // A variant with CLOSED-CAPTIONS=NONE says none of them has captions.
        let hasVariantWithoutCaptions = variantInfos.contains { $0.attributes["CLOSED-CAPTIONS"] == "NONE" }
        return HlsMultivariantPlaylist(
            baseUrl: url.absoluteString,
            tags: tags,
            variants: variants,
            videos: videos,
            audios: audios,
            subtitles: subtitles,
            closedCaptions: closedCaptions,
            muxedAudioFormat: muxedAudioFormat,
            muxedCaptionFormats: hasVariantWithoutCaptions ? [] : muxedCaptionFormats,
            hasIndependentSegments: hasIndependentSegments,
            variableDefinitions: variables,
            sessionKeyDrmInitData: [],
            contentSteeringInfo: nil,
            iFrameVariants: iFrameVariants
        )
    }

    func makeVariant(
        _ info: VariantInfo,
        index: Int,
        variables: [String: String]
    ) throws -> HlsMultivariantPlaylist.Variant {
        let value = { (name: String) in
            info.attributes[name].map { replaceVariableReferences($0, variables: variables) }
        }
        guard let peakBitrate = value("BANDWIDTH").flatMap(Int.init) else {
            throw ParseError.malformed("EXT-X-STREAM-INF without BANDWIDTH")
        }

        // A variant is its video, or its audio when it has no video.
        var format = VideoFormat()
        format.id = String(index)
        format.containerMimeType = .applicationM3U8
        format.codecs = value("CODECS")
        format.peakBitrate = peakBitrate
        format.averageBitrate = value("AVERAGE-BANDWIDTH").flatMap(Int.init)
        format.codec = Codecs.mediaMimeType(ofType: .video, in: format.codecs).map(VideoCodec.init)

        if let resolution = value("RESOLUTION") {
            let parts = resolution.split(separator: "x").compactMap { Int($0) }
            // Zero or negative sizes are treated as unknown.
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                format.size = VideoSize(width: parts[0], height: parts[1])
            }
        }
        format.frameRate = value("FRAME-RATE").flatMap(Float.init)
        // The range is that of the transfer function: SDR leaves it unknown.
        switch value("VIDEO-RANGE").flatMap(VideoRange.init(hlsAttribute:)) {
        case .pq?: format.transferFunction = .pq
        case .hlg?: format.transferFunction = .hlg
        default: break
        }
        format.supplementalCodecs = supplementalCodecs(value("SUPPLEMENTAL-CODECS"), videoRange: value("VIDEO-RANGE"))
        let hasVideo = format.size != nil || format.codec != nil

        let closedCaptions = value("CLOSED-CAPTIONS")
        return HlsMultivariantPlaylist.Variant(
            url: info.url,
            format: hasVideo ? AnyFormat(format) : AnyFormat(audioFormat(ofAudioOnlyVariant: format)),
            videoGroupId: value("VIDEO"),
            audioGroupId: value("AUDIO"),
            subtitleGroupId: value("SUBTITLES"),
            // CLOSED-CAPTIONS=NONE says there are none.
            captionGroupId: closedCaptions == "NONE" ? nil : closedCaptions,
            pathwayId: value("PATHWAY-ID"),
            stableVariantId: value("STABLE-VARIANT-ID")
        )
    }

    /// The format of a variant without video: its common attributes and the codec of its audio.
    func audioFormat(ofAudioOnlyVariant variant: VideoFormat) -> AudioFormat {
        var format = AudioFormat()
        format.id = variant.id
        format.containerMimeType = variant.containerMimeType
        format.codecs = variant.codecs
        format.peakBitrate = variant.peakBitrate
        format.averageBitrate = variant.averageBitrate
        format.codec = Codecs.mediaMimeType(ofType: .audio, in: variant.codecs).map(AudioCodec.init)
        return format
    }

    /// The supplemental video codec of a variant: the first one of `SUPPLEMENTAL-CODECS`, a list of codecs with their
    /// compatibility brands (`dvh1.08.07/db4h`), if it is a Dolby Vision layer that agrees with the video range.
    func supplementalCodecs(_ attribute: String?, videoRange: String?) -> String? {
        // Only the first codec is read.
        guard let first = attribute?.split(separator: ",").first else { return nil }
        let parts = first.split(separator: "/", omittingEmptySubsequences: false)
        let supplementalCodec = parts[0].trimmingCharacters(in: .whitespaces)
        let profiles = parts.count > 1 ? String(parts[1]) : nil
        guard Codecs.mediaMimeType(forCodec: supplementalCodec) == .videoDolbyVision else {
            SELogger.debug(.playlist, "Supplemental codec \(supplementalCodec) isn't read")
            return nil
        }
        // The brand says which range the enhancement layer is for: PQ (db1p), SDR (db2g) or HLG (db4g, db4h).
        guard let videoRange, let profiles else { return nil }
        let agrees = switch videoRange.uppercased() {
        case "PQ": profiles == "db1p"
        case "SDR": profiles == "db2g"
        case "HLG": profiles.hasPrefix("db4")
        default: false
        }
        return agrees ? supplementalCodec : nil
    }

    func selectionFlags(_ attributes: AttributeList) -> SelectionFlags {
        var flags: SelectionFlags = []
        if attributes["DEFAULT"] == "YES" { flags.insert(.default) }
        if attributes["FORCED"] == "YES" { flags.insert(.forced) }
        if attributes["AUTOSELECT"] == "YES" { flags.insert(.autoselect) }
        return flags
    }

    func roleFlags(_ attributes: AttributeList) -> RoleFlags {
        guard let characteristics = attributes["CHARACTERISTICS"] else {
            return []
        }
        var flags: RoleFlags = []
        let values = characteristics.split(separator: ",")
        if values.contains("public.accessibility.describes-video") { flags.insert(.describesVideo) }
        if values.contains("public.accessibility.transcribes-spoken-dialog") { flags.insert(.transcribesDialog) }
        if values.contains("public.accessibility.describes-music-and-sound") { flags.insert(.describesMusicAndSound) }
        if values.contains("public.easy-to-read") { flags.insert(.easyToRead) }
        return flags
    }
}

// MARK: - Media playlist

private extension HlsPlaylistParser {
    // swiftlint:disable:next function_body_length
    func parseMediaPlaylist(lines: [String], url: URL) throws -> HlsMediaPlaylist {
        var variables: [String: String] = [:]
        var tags: [String] = []
        var hasIndependentSegments = multivariantPlaylist?.hasIndependentSegments ?? false
        var playlistType = HlsMediaPlaylist.PlaylistType.unknown
        var startOffset = CMTime.invalid
        var preciseStart = false
        var mediaSequence = 0
        var version = 1
        var targetDuration = CMTime.zero
        var hasEndTag = false
        var hasDiscontinuitySequence = false
        var discontinuitySequence = 0
        var serverControl = HlsMediaPlaylist.ServerControl.none
        var isIFramesOnly = false
        var partTargetDuration = CMTime.invalid
        var preloadHint: AttributeList?

        var programDateTime: Date?
        var segments: [HlsMediaPlaylist.Segment] = []
        // The parts since the last segment: they become its parts once its URI comes.
        var segmentParts: [HlsMediaPlaylist.Part] = []
        var nextPartByteRangeOffset = 0
        var renditionReports: [(url: URL, lastMediaSequence: Int?, lastPartIndex: Int?)] = []

        // Per segment, reset after each URI.
        var segmentDuration = CMTime.zero
        var segmentTitle = ""
        var segmentByteRangeLength: Int?
        var segmentByteRangeOffset: Int?
        var hasGapTag = false

        // Carried over from segment to segment.
        var relativeDiscontinuitySequence = 0
        var segmentStartTime = CMTime.zero
        var nextByteRangeOffset = 0
        var initializationSegment: HlsMediaPlaylist.InitializationSegment?
        var encryption: HlsMediaPlaylist.SegmentEncryption?

        // Segments of a single-file playlist share one URI, and others often repeat a few: each is resolved once, as
        // resolving a URL against the playlist's is the larger part of parsing a long playlist.
        var resolvedUrls: [String: URL] = [:]
        let resolve = { (uri: String) throws -> URL in
            let uri = replaceVariableReferences(uri, variables: variables)
            if let resolved = resolvedUrls[uri] { return resolved }
            guard let resolved = URL(string: uri, relativeTo: url)?.absoluteURL else {
                throw ParseError.malformed("URI \(uri)")
            }
            resolvedUrls[uri] = resolved
            return resolved
        }

        for line in lines {
            if line.hasPrefix("#EXT") { tags.append(line) }

            if line.hasPrefix(Tag.playlistType) {
                switch value(of: line, tag: Tag.playlistType) {
                case "VOD": playlistType = .vod
                case "EVENT": playlistType = .event
                default: break
                }
            } else if line.hasPrefix(Tag.define) {
                let attributes = AttributeList(line, prefix: Tag.define)
                if let name = attributes["NAME"], let value = attributes["VALUE"] {
                    variables[name] = value
                } else if let name = attributes["IMPORT"], let value = multivariantPlaylist?.variableDefinitions[name] {
                    variables[name] = value
                } else if let name = attributes["QUERYPARAM"],
                          let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == name })?.value {
                    variables[name] = value
                }
            } else if line.hasPrefix(Tag.start) {
                let attributes = AttributeList(line, prefix: Tag.start)
                if let offset = attributes["TIME-OFFSET"].flatMap(Double.init) {
                    startOffset = CMTime(seconds: offset, preferredTimescale: .microsecondsTimescale)
                }
                preciseStart = attributes["PRECISE"] == "YES"
            } else if line.hasPrefix(Tag.serverControl) {
                let attributes = AttributeList(line, prefix: Tag.serverControl)
                let seconds = { (name: String) -> CMTime in
                    attributes[name].flatMap(Double.init)
                        .map { CMTime(seconds: $0, preferredTimescale: .microsecondsTimescale) } ?? .invalid
                }
                serverControl = .init(
                    skipUntil: seconds("CAN-SKIP-UNTIL"),
                    canSkipDateRanges: attributes["CAN-SKIP-DATERANGES"] == "YES",
                    holdBack: seconds("HOLD-BACK"),
                    partHoldBack: seconds("PART-HOLD-BACK"),
                    canBlockReload: attributes["CAN-BLOCK-RELOAD"] == "YES"
                )
            } else if line.hasPrefix(Tag.partInf) {
                let attributes = AttributeList(line, prefix: Tag.partInf)
                guard let seconds = attributes["PART-TARGET"].flatMap(Double.init) else {
                    throw ParseError.malformed(line)
                }
                partTargetDuration = CMTime(seconds: seconds, preferredTimescale: .microsecondsTimescale)
            } else if line.hasPrefix(Tag.part) {
                let attributes = AttributeList(line, prefix: Tag.part)
                guard let uri = attributes["URI"],
                      let seconds = attributes["DURATION"].flatMap(Double.init) else {
                    throw ParseError.malformed(line)
                }
                var byteRangeOffset = 0
                var byteRangeLength: Int?
                if let byteRange = attributes["BYTERANGE"].map({ replaceVariableReferences($0, variables: variables) }) {
                    let parsed = try parseByteRange(byteRange, defaultOffset: nextPartByteRangeOffset)
                    byteRangeLength = parsed.length
                    byteRangeOffset = parsed.offset
                    nextPartByteRangeOffset = parsed.offset + parsed.length
                }
                let duration = CMTime(seconds: seconds, preferredTimescale: .microsecondsTimescale)
                try segmentParts.append(.init(
                    url: resolve(uri),
                    initializationSegment: initializationSegment,
                    duration: duration,
                    relativeDiscontinuitySequence: relativeDiscontinuitySequence,
                    relativeStartTime: segmentStartTime + segmentParts.reduce(.zero) { $0 + $1.duration },
                    encryption: encryption,
                    byteRangeOffset: byteRangeOffset,
                    byteRangeLength: byteRangeLength,
                    hasGapTag: attributes["GAP"] == "YES",
                    isIndependent: attributes["INDEPENDENT"] == "YES",
                    isPreload: false
                ))
            } else if line.hasPrefix(Tag.preloadHint) {
                preloadHint = AttributeList(line, prefix: Tag.preloadHint)
            } else if line.hasPrefix(Tag.renditionReport) {
                let attributes = AttributeList(line, prefix: Tag.renditionReport)
                guard let uri = attributes["URI"] else {
                    throw ParseError.malformed(line)
                }
                try renditionReports.append((
                    url: resolve(uri),
                    lastMediaSequence: attributes["LAST-MSN"].flatMap { Int($0) },
                    lastPartIndex: attributes["LAST-PART"].flatMap { Int($0) }
                ))
            } else if line.hasPrefix(Tag.skip) {
                // The segments the server left out are those of the previous playlist from this one's first.
                let attributes = AttributeList(line, prefix: Tag.skip)
                guard let count = attributes["SKIPPED-SEGMENTS"].flatMap({ Int($0) }) else {
                    throw ParseError.malformed(line)
                }
                guard let previous = previousMediaPlaylist, segments.isEmpty else {
                    throw ParseError.deltaUpdateUnusable
                }
                let first = mediaSequence - previous.mediaSequence
                guard first >= 0, first + count <= previous.segments.count else {
                    throw ParseError.deltaUpdateUnusable
                }
                for segment in previous.segments[first ..< (first + count)] {
                    let discontinuity = previous.discontinuitySequence + segment.relativeDiscontinuitySequence
                        - discontinuitySequence
                    segments.append(segment.moved(
                        relativeStartTime: segmentStartTime,
                        relativeDiscontinuitySequence: discontinuity
                    ))
                    segmentStartTime = segmentStartTime + segment.duration
                    if let length = segment.byteRangeLength {
                        nextByteRangeOffset = segment.byteRangeOffset + length
                    }
                    relativeDiscontinuitySequence = discontinuity
                    initializationSegment = segment.initializationSegment
                    encryption = segment.encryption
                }
            } else if line.hasPrefix(Tag.targetDuration) {
                guard let seconds = Int(value(of: line, tag: Tag.targetDuration)) else {
                    throw ParseError.malformed(line)
                }
                targetDuration = CMTime(value: CMTimeValue(seconds), timescale: 1)
            } else if line.hasPrefix(Tag.mediaSequence) {
                guard let sequence = Int(value(of: line, tag: Tag.mediaSequence)), sequence >= 0 else {
                    throw ParseError.malformed(line)
                }
                mediaSequence = sequence
            } else if line.hasPrefix(Tag.version) {
                version = Int(value(of: line, tag: Tag.version)) ?? version
            } else if line.hasPrefix(Tag.discontinuitySequence) {
                guard let sequence = Int(value(of: line, tag: Tag.discontinuitySequence)) else {
                    throw ParseError.malformed(line)
                }
                hasDiscontinuitySequence = true
                discontinuitySequence = sequence
            } else if line == Tag.discontinuity.rawValue {
                relativeDiscontinuitySequence += 1
            } else if line == Tag.independentSegments.rawValue {
                hasIndependentSegments = true
            } else if line == Tag.endList.rawValue {
                hasEndTag = true
            } else if line == Tag.iFramesOnly.rawValue {
                isIFramesOnly = true
            } else if line == Tag.gap.rawValue {
                hasGapTag = true
            } else if line.hasPrefix(Tag.programDateTime) {
                if programDateTime == nil {
                    programDateTime = parseDate(value(of: line, tag: Tag.programDateTime))
                        .map { $0.addingTimeInterval(-segmentStartTime.seconds) }
                }
            } else if line.hasPrefix(Tag.map) {
                let attributes = AttributeList(line, prefix: Tag.map)
                guard let uri = attributes["URI"] else {
                    throw ParseError.malformed(line)
                }
                var offset = 0
                var length: Int?
                if let byteRange = attributes["BYTERANGE"].map({ replaceVariableReferences($0, variables: variables) }) {
                    let parsed = try parseByteRange(byteRange, defaultOffset: 0)
                    length = parsed.length
                    offset = parsed.offset
                }
                initializationSegment = try .init(
                    url: resolve(uri),
                    byteRangeOffset: offset,
                    byteRangeLength: length,
                    encryption: encryption
                )
            } else if line.hasPrefix(Tag.key) {
                let attributes = AttributeList(line, prefix: Tag.key)
                let method = attributes["METHOD"] ?? "NONE"
                let keyFormat = attributes["KEYFORMAT"] ?? "identity"
                switch method {
                case "NONE":
                    encryption = nil
                case "AES-128" where keyFormat == "identity":
                    guard let uri = attributes["URI"] else {
                        throw ParseError.malformed(line)
                    }
                    let iv = try attributes["IV"].map { try parseIV($0) }
                    encryption = try .init(keyUrl: resolve(uri), iv: iv)
                default:
                    throw ParseError.unsupported("EXT-X-KEY METHOD=\(method) KEYFORMAT=\(keyFormat)")
                }
            } else if line.hasPrefix(Tag.byteRange) {
                let byteRange = value(of: line, tag: Tag.byteRange)
                let parsed = try parseByteRange(byteRange, defaultOffset: nextByteRangeOffset)
                segmentByteRangeLength = parsed.length
                segmentByteRangeOffset = parsed.offset
            } else if line.hasPrefix(Tag.inf) {
                let content = value(of: line, tag: Tag.inf)
                let parts = content.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                guard let seconds = parts.first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else {
                    throw ParseError.malformed(line)
                }
                segmentDuration = CMTime(seconds: seconds, preferredTimescale: .microsecondsTimescale)
                segmentTitle = parts.count > 1 ? String(parts[1]) : ""
            } else if !line.hasPrefix("#") {
                let byteRangeOffset = segmentByteRangeLength == nil ? 0 : segmentByteRangeOffset ?? nextByteRangeOffset
                // An initialization section uses the encryption in effect where it's declared; it may be encrypted
                // even if the segment isn't.
                try segments.append(.init(
                    url: resolve(line),
                    initializationSegment: initializationSegment,
                    duration: segmentDuration,
                    title: segmentTitle,
                    relativeDiscontinuitySequence: relativeDiscontinuitySequence,
                    relativeStartTime: segmentStartTime,
                    encryption: encryption,
                    byteRangeOffset: byteRangeOffset,
                    byteRangeLength: segmentByteRangeLength,
                    hasGapTag: hasGapTag,
                    parts: segmentParts
                ))
                segmentParts = []

                segmentStartTime = segmentStartTime + segmentDuration
                if let segmentByteRangeLength {
                    nextByteRangeOffset = byteRangeOffset + segmentByteRangeLength
                }
                segmentDuration = .zero
                segmentTitle = ""
                segmentByteRangeLength = nil
                segmentByteRangeOffset = nil
                hasGapTag = false
            }
        }

        var startTime = programDateTime.map {
            CMTime(seconds: $0.timeIntervalSince1970, preferredTimescale: .microsecondsTimescale)
        } ?? .zero
        // A delta update may leave out the only #EXT-X-PROGRAM-DATE-TIME: its first segment is in the previous
        // playlist, which dates it.
        var hasProgramDateTime = programDateTime != nil
        if !hasProgramDateTime, let previous = previousMediaPlaylist, previous.hasProgramDateTime,
           previous.segments.indices.contains(mediaSequence - previous.mediaSequence) {
            startTime = previous.startTime + previous.segments[mediaSequence - previous.mediaSequence].relativeStartTime
            hasProgramDateTime = true
        }

        // The parts of the segment being made, and the part the server announces next. A playlist that ended has
        // nothing more to come.
        var trailingParts = hasEndTag ? [] : segmentParts
        if !hasEndTag, partTargetDuration.isValid, let preloadHint, preloadHint["TYPE"] == "PART",
           let uri = preloadHint["URI"] {
            let offset = preloadHint["BYTERANGE-START"].flatMap { Int($0) } ?? 0
            let length = preloadHint["BYTERANGE-LENGTH"].flatMap { Int($0) }
            try trailingParts.append(.init(
                url: resolve(uri),
                initializationSegment: initializationSegment,
                duration: partTargetDuration,
                relativeDiscontinuitySequence: relativeDiscontinuitySequence,
                relativeStartTime: segmentStartTime + segmentParts.reduce(.zero) { $0 + $1.duration },
                encryption: encryption,
                byteRangeOffset: offset,
                byteRangeLength: length,
                hasGapTag: false,
                isIndependent: false,
                isPreload: true
            ))
        }

        // A report without the last segment or part is of a rendition as far along as this one.
        let availableParts = segmentParts.isEmpty ? (segments.last?.parts ?? []) : segmentParts
        var reports: [URL: HlsMediaPlaylist.RenditionReport] = [:]
        let lastMediaSequence = mediaSequence + segments.count - (segmentParts.isEmpty ? 1 : 0)
        let lastPartIndex = partTargetDuration.isValid ? availableParts.count - 1 : nil
        for report in renditionReports {
            reports[report.url] = .init(
                url: report.url,
                lastMediaSequence: report.lastMediaSequence ?? lastMediaSequence,
                lastPartIndex: report.lastPartIndex ?? lastPartIndex
            )
        }

        return HlsMediaPlaylist(
            baseUrl: url.absoluteString,
            tags: tags,
            hasIndependentSegments: hasIndependentSegments,
            playlistType: playlistType,
            startOffset: startOffset,
            preciseStart: preciseStart,
            startTime: startTime,
            hasDiscontinuitySequence: hasDiscontinuitySequence,
            discontinuitySequence: discontinuitySequence,
            mediaSequence: mediaSequence,
            version: version,
            targetDuration: targetDuration,
            hasEndTag: hasEndTag,
            hasProgramDateTime: hasProgramDateTime,
            segments: segments,
            partTargetDuration: partTargetDuration,
            trailingParts: trailingParts,
            serverControl: serverControl,
            renditionReports: reports,
            isIFramesOnly: isIFramesOnly
        )
    }

    func parseByteRange(_ value: String, defaultOffset: Int) throws -> (length: Int, offset: Int) {
        let parts = value.split(separator: "@")
        guard let length = parts.first.flatMap({ Int($0) }) else {
            throw ParseError.malformed("BYTERANGE \(value)")
        }
        let offset = parts.count > 1 ? Int(parts[1]) ?? defaultOffset : defaultOffset
        return (length, offset)
    }

    /// The initialization vector of an `IV` attribute: a hexadecimal 128-bit integer.
    func parseIV(_ value: String) throws -> Data {
        var hex = Substring(value)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        let digits = try hex.map { character -> UInt8 in
            guard let digit = character.hexDigitValue else {
                throw ParseError.malformed("IV \(value)")
            }
            return UInt8(digit)
        }
        guard !digits.isEmpty, digits.count <= Self.ivLength * 2 else {
            throw ParseError.malformed("IV \(value)")
        }
        // Shorter values are left-padded.
        let padded = [UInt8](repeating: 0, count: Self.ivLength * 2 - digits.count) + digits
        let bytes = stride(from: 0, to: padded.count, by: 2).map { padded[$0] << 4 | padded[$0 + 1] }
        return Data(bytes)
    }

    static var ivLength: Int { 16 }

    func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

// MARK: - Lines and attributes

private extension HlsPlaylistParser {
    func value(of line: String, tag: Tag) -> String {
        String(line.dropFirst(tag.rawValue.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Replaces `{$NAME}` with the variable's value; a reference to an undefined variable stays as it is.
    func replaceVariableReferences(_ string: String, variables: [String: String]) -> String {
        guard !variables.isEmpty, string.contains("{$") else { return string }
        var result = ""
        var remainder = Substring(string)
        while let start = remainder.range(of: "{$") {
            result += remainder[..<start.lowerBound]
            guard let end = remainder[start.upperBound...].firstIndex(of: "}") else {
                result += remainder[start.lowerBound...]
                return result
            }
            let name = String(remainder[start.upperBound ..< end])
            result += variables[name] ?? "{$\(name)}"
            remainder = remainder[remainder.index(after: end)...]
        }
        return result + remainder
    }

    /// The tags of HLS playlists, by the text that starts their line.
    enum Tag: String, CaseIterable {
        case playlistHeader = "#EXTM3U"
        case version = "#EXT-X-VERSION:"
        case playlistType = "#EXT-X-PLAYLIST-TYPE:"
        case define = "#EXT-X-DEFINE:"
        case serverControl = "#EXT-X-SERVER-CONTROL:"
        case streamInf = "#EXT-X-STREAM-INF:"
        case media = "#EXT-X-MEDIA:"
        case targetDuration = "#EXT-X-TARGETDURATION:"
        case discontinuity = "#EXT-X-DISCONTINUITY"
        case discontinuitySequence = "#EXT-X-DISCONTINUITY-SEQUENCE:"
        case programDateTime = "#EXT-X-PROGRAM-DATE-TIME:"
        case map = "#EXT-X-MAP:"
        case independentSegments = "#EXT-X-INDEPENDENT-SEGMENTS"
        case inf = "#EXTINF:"
        case mediaSequence = "#EXT-X-MEDIA-SEQUENCE:"
        case start = "#EXT-X-START:"
        case endList = "#EXT-X-ENDLIST"
        case key = "#EXT-X-KEY:"
        case byteRange = "#EXT-X-BYTERANGE:"
        case gap = "#EXT-X-GAP"
        case iFrameStreamInf = "#EXT-X-I-FRAME-STREAM-INF:"
        case iFramesOnly = "#EXT-X-I-FRAMES-ONLY"
        case partInf = "#EXT-X-PART-INF:"
        case part = "#EXT-X-PART:"
        case preloadHint = "#EXT-X-PRELOAD-HINT:"
        case renditionReport = "#EXT-X-RENDITION-REPORT:"
        case skip = "#EXT-X-SKIP:"

        /// The tags only a media playlist has.
        static let mediaPlaylistTags: [Tag] = [
            .targetDuration, .mediaSequence, .inf, .key, .byteRange, .discontinuity, .discontinuitySequence,
            .programDateTime, .endList, .playlistType, .map, .partInf, .part, .preloadHint, .skip,
        ]
    }
}

/// An attribute list: `NAME=VALUE` pairs separated by commas, values quoted or not.
struct AttributeList: CustomStringConvertible {
    private var values: [String: String] = [:]

    fileprivate init(_ line: String, prefix tag: HlsPlaylistParser.Tag) {
        var remainder = Substring(line.dropFirst(tag.rawValue.count))
        while !remainder.isEmpty {
            guard let equals = remainder.firstIndex(of: "=") else { break }
            let name = remainder[..<equals].trimmingCharacters(in: .whitespaces)
            remainder = remainder[remainder.index(after: equals)...]

            let value: Substring
            if remainder.first == "\"" {
                let afterQuote = remainder.index(after: remainder.startIndex)
                let closing = remainder[afterQuote...].firstIndex(of: "\"") ?? remainder.endIndex
                value = remainder[afterQuote ..< closing]
                remainder = closing < remainder.endIndex ? remainder[remainder.index(after: closing)...] : ""
            } else {
                let comma = remainder.firstIndex(of: ",") ?? remainder.endIndex
                value = remainder[..<comma]
                remainder = remainder[comma...]
            }
            values[name] = String(value).trimmingCharacters(in: .whitespaces)

            if remainder.first == "," { remainder = remainder.dropFirst() }
        }
    }

    subscript(name: String) -> String? { values[name] }

    var description: String { values.description }
}

private extension String {
    func hasPrefix(_ tag: HlsPlaylistParser.Tag) -> Bool {
        hasPrefix(tag.rawValue)
    }
}

private extension CMTimeScale {
    static let microsecondsTimescale: CMTimeScale = 1_000_000
}

extension HlsPlaylistParser.ParseError: PlaybackErrorCodeProviding {
    public var errorCode: PlaybackErrorCode {
        switch self {
        case .notAPlaylist,
             .malformed,
             .deltaUpdateUnusable: .parsingManifestMalformed
        case .unsupported: .parsingManifestUnsupported
        }
    }
}
