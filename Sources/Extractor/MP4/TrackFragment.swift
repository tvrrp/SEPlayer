//
//  TrackFragment.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.06.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.mp4.TrackFragment
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

final class TrackFragment {
    var header: DefaultSampleValues?
    var atomPosition: Int
    var dataPosition: Int
    var auxiliaryDataPosition: Int
    var trunCount: Int
    var sampleCount: Int
    var trunDataPosition: [Int]
    var trunLength: [Int]
    var sampleSizeTable: [Int]
    var sampleDecodeTimes: [CMTime]
    var samplePresentationTimes: [CMTime]
    var sampleDurations: [CMTime]
    var sampleIsSyncFrameTable: [Bool]
    var nextFragmentDecodeTime: CMTimeValue
    var nextFragmentDecodeTimeIncludesMoov: Bool

    init(
        header: DefaultSampleValues? = nil,
        atomPosition: Int = 0,
        dataPosition: Int = 0,
        auxiliaryDataPosition: Int = 0,
        trunCount: Int = 0,
        sampleCount: Int = 0,
        trunDataPosition: [Int] = [],
        trunLength: [Int] = [],
        sampleSizeTable: [Int] = [],
        sampleDecodeTimes: [CMTime] = [],
        samplePresentationTimes: [CMTime] = [],
        sampleDurations: [CMTime] = [],
        sampleIsSyncFrameTable: [Bool] = [],
        nextFragmentDecodeTime: CMTimeValue = 0,
        nextFragmentDecodeTimeIncludesMoov: Bool = false
    ) {
        self.header = header
        self.atomPosition = atomPosition
        self.dataPosition = dataPosition
        self.auxiliaryDataPosition = auxiliaryDataPosition
        self.trunCount = trunCount
        self.sampleCount = sampleCount
        self.trunDataPosition = trunDataPosition
        self.trunLength = trunLength
        self.sampleSizeTable = sampleSizeTable
        self.sampleDecodeTimes = sampleDecodeTimes
        self.samplePresentationTimes = samplePresentationTimes
        self.sampleDurations = sampleDurations
        self.sampleIsSyncFrameTable = sampleIsSyncFrameTable
        self.nextFragmentDecodeTime = nextFragmentDecodeTime
        self.nextFragmentDecodeTimeIncludesMoov = nextFragmentDecodeTimeIncludesMoov
    }

    func reset() {
        trunCount = 0
        nextFragmentDecodeTime = 0
        nextFragmentDecodeTimeIncludesMoov = false
    }

    func initTables(trunCount: Int, sampleCount: Int) {
        self.trunCount = trunCount
        self.sampleCount = sampleCount
        if trunLength.count < trunCount {
            trunDataPosition = Array(repeating: 0, count: trunCount)
            trunLength = Array(repeating: 0, count: trunCount)
        }

        if sampleSizeTable.count < sampleCount {
            let tableSize = (sampleCount * 125) / 100
            sampleSizeTable = Array(repeating: 0, count: tableSize)
            sampleDecodeTimes = Array(repeating: .zero, count: tableSize)
            samplePresentationTimes = Array(repeating: .zero, count: tableSize)
            sampleDurations = Array(repeating: .zero, count: tableSize)
            sampleIsSyncFrameTable = Array(repeating: false, count: tableSize)
        }
    }

    @inline(__always)
    func timingInfo(at index: Int) -> CMSampleTimingInfo {
        CMSampleTimingInfo(
            duration: sampleDurations[index],
            presentationTimeStamp: samplePresentationTimes[index],
            decodeTimeStamp: sampleDecodeTimes[index]
        )
    }
}
