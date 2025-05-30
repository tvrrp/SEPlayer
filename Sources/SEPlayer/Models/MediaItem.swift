//
//  MediaItem.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public struct MediaItem: Hashable {
    let url: URL

    public init(url: URL) {
        self.url = url
    }
}
