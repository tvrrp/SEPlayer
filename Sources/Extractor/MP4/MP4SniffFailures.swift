//
//  MP4SniffFailures.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.06.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.mp4.AtomSizeTooSmallSniffFailure
//    androidx.media3.extractor.mp4.IncorrectFragmentationSniffFailure
//    androidx.media3.extractor.mp4.NoDeclaredBrandSniffFailure
//    androidx.media3.extractor.mp4.UnsupportedBrandsSniffFailure
//  Copyright (C) 2024 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

struct AtomSizeTooSmallSniffFailure: SniffFailure {
    let atomType: MP4Box.BoxType?
    let atomSize: Int
    let minimumHeaderSize: Int
}

public struct IncorrectFragmentationSniffFailure: SniffFailure {
    let fileIsFragmented: Bool

    private init(fileIsFragmented: Bool) {
        self.fileIsFragmented = fileIsFragmented
    }

    static func fileFragmented() -> Self {
        Self(fileIsFragmented: true)
    }

    static func fileNotFragmented() -> Self {
        Self(fileIsFragmented: false)
    }
}

public struct NoDeclaredBrandSniffFailure: SniffFailure {}

public struct UnsupportedBrandsSniffFailure: SniffFailure {
    let majorBrand: UInt32
    let compatibleBrands: [UInt32]
}
