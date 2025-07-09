//
//  TrackFragment.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.06.2025.
//

struct TrackFragment {
    var header: DefaultSampleValues?
    var atomPosition: Int
    var dataPosition: Int
    var auxiliaryDataPosition: Int
    var trunCount: Int
    var sampleCount: Int
    var trunDataPosition: [Int]
    var trunLength: [Int]
    var sampleSizeTable: [Int]
    var samplePresentationTimesUs: [Int]
    var sampleIsSyncFrameTable: [Bool]
    var nextFragmentDecodeTime: Int
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
        samplePresentationTimesUs: [Int] = [],
        sampleIsSyncFrameTable: [Bool] = [],
        nextFragmentDecodeTime: Int = 0,
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
        self.samplePresentationTimesUs = samplePresentationTimesUs
        self.sampleIsSyncFrameTable = sampleIsSyncFrameTable
        self.nextFragmentDecodeTime = nextFragmentDecodeTime
        self.nextFragmentDecodeTimeIncludesMoov = nextFragmentDecodeTimeIncludesMoov
    }

    mutating func reset() {
        trunCount = 0
        nextFragmentDecodeTime = 0
        nextFragmentDecodeTimeIncludesMoov = false
    }

    mutating func initTables(trunCount: Int, sampleCount: Int) {
        self.trunCount = trunCount
        self.sampleCount = sampleCount
        if trunLength.count < trunCount {
            trunDataPosition = Array(repeating: 0, count: trunCount)
            trunLength = Array(repeating: 0, count: trunCount)
        }

        if sampleSizeTable.count < sampleCount {
            let tableSize = (sampleCount * 125) / 100
            sampleSizeTable = Array(repeating: 0, count: tableSize)
            samplePresentationTimesUs = Array(repeating: 0, count: tableSize)
            sampleIsSyncFrameTable = Array(repeating: false, count: tableSize)
        }
    }

    
}
