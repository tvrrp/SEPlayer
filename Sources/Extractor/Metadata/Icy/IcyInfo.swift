//
//  IcyInfo.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.metadata.icy.IcyInfo
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import Foundation
import SEPlayerCommon

/// The ICY metadata of a moment of a stream: the title playing now.
public struct IcyInfo: Metadata.Entry {
    /// The metadata as it was sent.
    public let rawMetadata: Data
    /// The stream title, or `nil` if it isn't given.
    public let title: String?
    /// The stream URL, or `nil` if it isn't given.
    public let url: String?

    public var description: String {
        "ICY: title=\"\(title ?? "nil")\", url=\"\(url ?? "nil")\", rawMetadata.length=\"\(rawMetadata.count)\""
    }

    public init(rawMetadata: Data, title: String?, url: String?) {
        self.rawMetadata = rawMetadata
        self.title = title
        self.url = url
    }

    public func populateMediaMetadata(_ builder: MediaMetadata.Builder) {
        if let title {
            builder.setTitle(title)
        }
    }

    /// The title and the URL come from the raw metadata, so it alone tells entries apart.
    public static func == (lhs: IcyInfo, rhs: IcyInfo) -> Bool {
        lhs.rawMetadata == rhs.rawMetadata
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawMetadata)
    }
}
