//
//  DebugFormatting.swift
//  DemoApp
//

import CoreMedia
import SEPlayer
import UIKit

/// Text for the values the debug screen shows.
enum DebugFormat {
    static let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let boldFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    static let smallFont = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    static let smallBoldFont = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
    static let hudFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let hudBoldFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

    /// `1:02:03.456`, `2:03.456`, or `—` for a time that isn't known.
    static func time(_ time: CMTime, millis: Bool = true) -> String {
        guard time.isNumeric else { return time.isPositiveInfinity ? "∞" : "—" }
        let seconds = time.seconds
        let sign = seconds < 0 ? "-" : ""
        let total = abs(seconds)
        let hours = Int(total) / 3600
        let minutes = Int(total) / 60 % 60
        let wholeSeconds = Int(total) % 60
        let fraction = Int(((total - total.rounded(.down)) * 1000).rounded(.down))
        var text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, wholeSeconds)
            : String(format: "%d:%02d", minutes, wholeSeconds)
        if millis { text += String(format: ".%03d", fraction) }
        return sign + text
    }

    /// `12.3s`, or `—`.
    static func seconds(_ time: CMTime) -> String {
        guard time.isNumeric else { return "—" }
        return String(format: "%.1fs", time.seconds)
    }

    /// `6.21 Mbps`, `460 kbps`, or `—` for a value that isn't set.
    static func bitrate(_ bitsPerSecond: Int) -> String {
        guard bitsPerSecond > 0 else { return "—" }
        return bitrate(Double(bitsPerSecond))
    }

    static func bitrate(_ bitsPerSecond: Double) -> String {
        switch bitsPerSecond {
        case 1_000_000...: String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
        case 1_000...: String(format: "%.0f kbps", bitsPerSecond / 1_000)
        default: String(format: "%.0f bps", bitsPerSecond)
        }
    }

    /// `6.2M`, `460k`.
    static func shortBitrate(_ bitsPerSecond: Int) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1fM", Double(bitsPerSecond) / 1_000_000)
            : String(format: "%.0fk", Double(bitsPerSecond) / 1_000)
    }

    static func stateColor(_ state: PlayerState) -> UIColor {
        switch state {
        case .idle: .systemGray
        case .buffering: .systemOrange
        case .ready: .systemGreen
        case .ended: .systemBlue
        }
    }

    /// One line about a format: what matters for its type.
    static func formatSummary(_ format: AnyFormat, type: TrackType) -> String {
        var parts = [String]()
        switch type {
        case .video:
            if format.width > 0, format.height > 0 { parts.append("\(format.width)×\(format.height)") }
            if format.frameRate > 0 { parts.append(String(format: "%.3g fps", format.frameRate)) }
        case .audio:
            if format.channelCount > 0 { parts.append("\(format.channelCount)ch") }
            if format.sampleRate > 0 { parts.append(String(format: "%.1f kHz", Double(format.sampleRate) / 1000)) }
        default:
            break
        }
        if format.bitrateValue > 0 { parts.append(bitrate(format.bitrateValue)) }
        if let codecs = format.codecs, !codecs.isEmpty {
            parts.append(codecs)
        } else if let mime = format.sampleMimeType {
            parts.append(mime.rawValue)
        }
        if let language = format.language { parts.append("[\(language)]") }
        if let label = format.label { parts.append("“\(label)”") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Every field of a format worth knowing, one per line.
    static func formatDetails(_ format: AnyFormat) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("id", format.id ?? "—"),
            ("label", format.label ?? "—"),
            ("language", format.language ?? "—"),
            ("container", format.containerMimeType?.rawValue ?? "—"),
            ("sample mime", format.sampleMimeType?.rawValue ?? "—"),
            ("codecs", format.codecs ?? "—"),
            ("bitrate", bitrate(format.bitrateValue)),
            ("avg bitrate", bitrate(format.averageBitrate ?? 0)),
            ("peak bitrate", bitrate(format.peakBitrate ?? 0)),
            ("selection", "\(format.selectionFlags)"),
            ("role", "\(format.roleFlags)"),
        ]
        if let video = format.video {
            rows += [
                ("size", "\(format.width)×\(format.height)"),
                ("frame rate", format.frameRate > 0 ? String(format: "%.3f", format.frameRate) : "—"),
                ("pixel ratio", String(format: "%.3f", video.size?.pixelWidthHeightRatio ?? 1)),
                ("rotation", "\(video.rotation)°"),
                ("video range", video.videoRange.map { "\($0)" } ?? "—"),
            ]
        }
        if let audio = format.audio {
            rows += [
                ("channels", format.channelCount > 0 ? "\(format.channelCount)" : "—"),
                ("sample rate", format.sampleRate > 0 ? "\(format.sampleRate) Hz" : "—"),
                ("encoder delay", "\(audio.encoderDelay)"),
                ("encoder padding", "\(audio.encoderPadding)"),
            ]
        }
        rows += [
            ("sample entry", format.sampleEntry.map { "\($0.bytes.count) B" } ?? "—"),
            ("boxes", format.boxes.isEmpty ? "—" : format.boxes.map(\.type.description).joined(separator: " ")),
        ]
        return rows
    }

    /// A short form of an id: a UUID by its first characters, an id made of others by its parts.
    static func id(_ value: Any) -> String {
        switch value {
        case let uuid as UUID:
            return String(uuid.uuidString.prefix(8)).lowercased()
        case let string as String:
            return string
        case let number as Int:
            return "\(number)"
        default:
            break
        }
        if let hashable = value as? AnyHashable, type(of: value) == AnyHashable.self {
            return id(hashable.base)
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { id($0.value) } ?? "—"
        }
        if !mirror.children.isEmpty {
            return mirror.children.map { id($0.value) }.joined(separator: " · ")
        }
        return String(describing: value)
    }

    /// Every stored property of an object, those of its superclasses first, with readable values.
    static func properties(of object: Any) -> [(String, String)] {
        var mirrors: [Mirror] = []
        var mirror: Mirror? = Mirror(reflecting: object)
        while let current = mirror {
            mirrors.insert(current, at: 0)
            mirror = current.superclassMirror
        }
        return mirrors.flatMap { mirror in
            mirror.children.compactMap { child in child.label.map { ($0, value(child.value)) } }
        }
    }

    /// A value as the debug screen shows it: limits that don't limit as `∞`, empty values as `—`.
    static func value(_ value: Any) -> String {
        switch value {
        case let size as CGSize:
            return size.width >= .greatestFiniteMagnitude || size.height >= .greatestFiniteMagnitude
                ? "∞" : "\(Int(size.width))×\(Int(size.height))"
        case let number as Int:
            return number == .max ? "∞" : "\(number)"
        case let flag as Bool:
            return "\(flag)"
        case let strings as [String]:
            return strings.isEmpty ? "—" : strings.joined(separator: ", ")
        case let types as Set<TrackType>:
            return types.isEmpty ? "—" : types.map(\.description).sorted().joined(separator: ", ")
        case let overrides as [TrackGroup: TrackSelectionOverride]:
            return overrides.isEmpty ? "—" : overrides.values
                .map { "\($0.type) “\($0.mediaTrackGroup.id)” \($0.trackIndices)" }
                .joined(separator: "; ")
        case let time as CMTime:
            return seconds(time)
        default:
            break
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .collection?,
             .dictionary?,
             .set?:
            return mirror.children.isEmpty ? "—" : "\(mirror.children.count) entries"
        case .optional?:
            return mirror.children.first.map { self.value($0.value) } ?? "—"
        default:
            // Option sets: none set reads as empty.
            if let raw = mirror.children.first(where: { $0.label == "rawValue" })?.value as? Int {
                return raw == 0 ? "—" : String(format: "0x%X", raw)
            }
            return String(describing: value)
        }
    }

    /// The track of a group that plays `playing`: the one with its id, or the same format.
    static func playingTrackIndex(in group: Tracks.Group, playing: AnyFormat?) -> Int? {
        guard let playing, group.type == playing.sampleMimeType.trackType else {
            return nil
        }
        let indices = 0 ..< group.length
        if let id = playing.id, let index = indices.first(where: { group.format(trackIndex: $0).id == id }) {
            return index
        }
        return indices.first { group.format(trackIndex: $0) == playing }
    }

    /// `▶` for the track that plays, `●` for the others of the selection, `○` for the rest.
    static func trackLine(_ group: Tracks.Group, trackIndex: Int, playing: AnyFormat?) -> (String, UIColor, Bool) {
        let isPlaying = playingTrackIndex(in: group, playing: playing) == trackIndex
        let selected = group.isTrackSelected(for: trackIndex)
        let support = group.trackSupport(for: trackIndex)
        let mark = isPlaying ? "▶" : selected ? "●" : "○"
        let line = "\(mark) \(trackIndex) [\(support)] "
            + formatSummary(group.format(trackIndex: trackIndex), type: group.type)
        let color: UIColor = isPlaying ? .systemGreen : selected ? .label : support == .handled ? .secondaryLabel : .systemRed
        return (line, color, isPlaying || selected)
    }

    static func host(of item: MediaItem) -> String {
        if let title = item.mediaMetadata.title, !title.isEmpty { return title }
        guard let url = item.localConfiguration?.url else {
            return item.mediaId.isEmpty ? "—" : item.mediaId
        }
        return url.host.map { "\($0)/…/\(url.lastPathComponent)" } ?? url.lastPathComponent
    }
}

/// An attributed text of `key  value` rows, the keys aligned.
struct DebugText {
    private(set) var text = NSMutableAttributedString()
    var keyWidth = 14
    var font = DebugFormat.font
    var boldFont = DebugFormat.boldFont

    mutating func header(_ title: String) {
        if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
        text.append(NSAttributedString(string: title.uppercased() + "\n", attributes: [
            .font: boldFont, .foregroundColor: UIColor.systemTeal,
        ]))
    }

    mutating func row(_ key: String, _ value: String, color: UIColor = .label) {
        let padded = key.padding(toLength: max(keyWidth, key.count + 1), withPad: " ", startingAt: 0)
        text.append(NSAttributedString(string: padded, attributes: [
            .font: font, .foregroundColor: UIColor.secondaryLabel,
        ]))
        text.append(NSAttributedString(string: value + "\n", attributes: [
            .font: font, .foregroundColor: color,
        ]))
    }

    mutating func line(_ value: String, color: UIColor = .label, bold: Bool = false) {
        text.append(NSAttributedString(string: value + "\n", attributes: [
            .font: bold ? boldFont : font, .foregroundColor: color,
        ]))
    }
}

/// The attributes of a format of any media as numbers, 0 when it has none.
extension Format where Scope == FormatAttributes.AnyMedia {
    var width: Int { video?.size?.width ?? 0 }
    var height: Int { video?.size?.height ?? 0 }
    var frameRate: Float { video?.frameRate ?? 0 }
    var channelCount: Int { audio?.channelCount ?? 0 }
    var sampleRate: Int { audio?.sampleRate ?? 0 }
    var bitrateValue: Int { bitrate ?? 0 }
}
