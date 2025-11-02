//
//  RendererCapabilities.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

public protocol RendererCapabilities {
    var trackType: TrackType { get }
    func supportsFormat(_ format: Format) -> Bool
}

struct EmptyRendererCapabilities: RendererCapabilities {
    let trackType: TrackType = .unknown
    func supportsFormat(_ format: Format) -> Bool { false }
}
