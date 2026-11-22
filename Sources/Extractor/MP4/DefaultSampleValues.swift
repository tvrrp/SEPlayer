//
//  DefaultSampleValues.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.06.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.mp4.DefaultSampleValues
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

struct DefaultSampleValues {
    let sampleDescriptionIndex: Int
    let durationTimeValue: CMTimeValue
    let size: Int
    let flags: Int
}
