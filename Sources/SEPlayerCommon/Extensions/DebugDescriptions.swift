//
//  DebugDescriptions.swift
//  SEPlayer
//

extension PlayerState: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .idle: "idle"
        case .buffering: "buffering"
        case .ready: "ready"
        case .ended: "ended"
        }
    }

    public var debugDescription: String { "PlayerState.\(description)" }
}

extension RepeatMode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .off: "off"
        case .one: "one"
        case .all: "all"
        }
    }

    public var debugDescription: String { "RepeatMode.\(description)" }
}

extension TrackType: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .unknown: "unknown"
        case .default: "default"
        case .audio: "audio"
        case .video: "video"
        case .text: "text"
        case .image: "image"
        case .metadata: "metadata"
        case .cameraMotion: "camera motion"
        case .none: "none"
        }
    }

    public var debugDescription: String { "TrackType.\(description)" }
}

extension FormatSupport: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .handled: "handled"
        case .exceedCapabilities: "exceeds capabilities"
        case .unsupportedDrm: "unsupported DRM"
        case .unsupportedSubtype: "unsupported subtype"
        case .unsupportedType: "unsupported type"
        }
    }

    public var debugDescription: String { "FormatSupport.\(description)" }
}

extension Format.VideoRange: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown: "unknown"
        case .sdr: "SDR"
        case .hlg: "HLG"
        case .pq: "PQ"
        }
    }
}

extension SelectionFlags: CustomStringConvertible {
    /// The flags by name, as `[default, forced]`.
    public var description: String {
        let names: [(SelectionFlags, String)] = [(.default, "default"), (.forced, "forced"), (.autoselect, "autoselect")]
        return "[\(names.filter { contains($0.0) }.map(\.1).joined(separator: ", "))]"
    }
}

extension RoleFlags: CustomStringConvertible {
    /// The flags by name, as `[main, caption]`.
    public var description: String {
        let names: [(RoleFlags, String)] = [
            (.main, "main"), (.alternate, "alternate"), (.supplementary, "supplementary"),
            (.commentary, "commentary"), (.dub, "dub"), (.emergency, "emergency"), (.caption, "caption"),
            (.subtitle, "subtitle"), (.sign, "sign"), (.describesVideo, "describes video"),
            (.describesMusicAndSound, "describes music and sound"),
            (.enhancedDialogIntelligibility, "enhanced dialog intelligibility"),
            (.transcribesDialog, "transcribes dialog"), (.easyToRead, "easy to read"), (.trickPlay, "trick play"),
            (.auxiliary, "auxiliary"),
        ]
        return "[\(names.filter { contains($0.0) }.map(\.1).joined(separator: ", "))]"
    }
}
