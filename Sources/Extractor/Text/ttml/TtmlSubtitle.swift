//
//  TtmlSubtitle.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.ttml.TtmlSubtitle
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics
import CoreMedia
import SEPlayerCommon

/// The cues of a TTML document, as events where paragraphs and images start and end.
struct TtmlSubtitle: Subtitle {
    let eventTimes: [CMTime]

    private let root: TtmlNode
    private let globalStyles: [String: TtmlStyle]
    private let regions: [String: TtmlRegion]
    private let images: [String: CGImage]

    /// - Parameter images: The images of the `smpte:image` elements, by their ids.
    init(root: TtmlNode, globalStyles: [String: TtmlStyle], regions: [String: TtmlRegion], images: [String: CGImage]) {
        self.root = root
        self.globalStyles = globalStyles
        self.regions = regions
        self.images = images
        eventTimes = root.eventTimes
    }

    func cues(at time: CMTime) -> [Cue] {
        root.cues(at: time, globalStyles: globalStyles, regions: regions, images: images)
    }
}
