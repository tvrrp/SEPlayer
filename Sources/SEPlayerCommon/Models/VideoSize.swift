//
//  VideoSize.swift
//  SEPlayerCommon
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.VideoSize
//  Copyright (C) 2021 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics

/// The size of the video being played.
public struct VideoSize: Hashable, Sendable {
    /// Before there is video: zero by zero.
    public static let unknown = VideoSize(width: 0, height: 0)

    /// The width in pixels.
    public let width: Int
    /// The height in pixels.
    public let height: Int
    /// The width of a pixel divided by its height: other than 1 for anamorphic video.
    public let pixelWidthHeightRatio: Float

    public init(width: Int, height: Int, pixelWidthHeightRatio: Float = 1) {
        self.width = width
        self.height = height
        self.pixelWidthHeightRatio = pixelWidthHeightRatio
    }

    /// The size the picture is shown at, its pixels made square.
    public var displaySize: CGSize {
        CGSize(width: CGFloat(width) * CGFloat(pixelWidthHeightRatio), height: CGFloat(height))
    }
}
