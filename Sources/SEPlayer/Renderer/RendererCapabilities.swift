//
//  RendererCapabilities.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

import CoreMedia

protocol RendererCapabilities {
    var trackType: TrackType { get }
    func supportsFormat(_ format: CMFormatDescription) -> Bool
}

struct EmptyRendererCapabilities: RendererCapabilities {
    let trackType: TrackType = .unknown
    func supportsFormat(_ format: CMFormatDescription) -> Bool { false }
}
