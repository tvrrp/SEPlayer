//
//  RendererCapabilities.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

import CoreMedia

protocol RendererCapabilities {
    func supportsFormat(_ format: CMFormatDescription) -> Bool
}

struct EmptyRendererCapabilities: RendererCapabilities {
    func supportsFormat(_ format: CMFormatDescription) -> Bool { false }
}
