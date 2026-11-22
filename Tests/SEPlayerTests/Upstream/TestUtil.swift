//
//  TestUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 03.11.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.test.utils.TestUtil
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
@testable import SEPlayer

struct TestUtil {
    static func buildTestData(length: Int) -> [UInt8] {
        buildTestData(length: length, seed: length)
    }

    static func buildTestData(length: Int, seed: Int) -> [UInt8] {
        let seed: UInt8 = seed <= Int(UInt8.max) ? UInt8(seed) : UInt8.max
        return (0 ..< length).map { _ in UInt8.random(in: 0 ..< seed) }
    }

    static func timelinesAreSame(lhs: Timeline, rhs: Timeline) -> Bool {
        NoIdOrShufflingTimeline(delegate: lhs)
            .equals(to: NoIdOrShufflingTimeline(delegate: rhs))
    }
}

private extension TestUtil {
    final class NoIdOrShufflingTimeline: Timeline, @unchecked Sendable {
        let delegate: Timeline

        init(delegate: Timeline) {
            self.delegate = delegate
        }

        func windowCount() -> Int {
            delegate.windowCount()
        }

        func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
            delegate.nextWindowIndex(windowIndex: windowIndex, repeatMode: repeatMode, shuffleModeEnabled: false)
        }

        func previousWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
            delegate.previousWindowIndex(windowIndex: windowIndex, repeatMode: repeatMode, shuffleModeEnabled: false)
        }

        func lastWindowIndex(shuffleModeEnabled: Bool) -> Int? {
            delegate.lastWindowIndex(shuffleModeEnabled: false)
        }

        func firstWindowIndex(shuffleModeEnabled: Bool) -> Int? {
            delegate.firstWindowIndex(shuffleModeEnabled: false)
        }

        @discardableResult
        func getWindow(windowIndex: Int, window: Window, defaultPositionProjection: CMTime) -> Window {
            delegate.getWindow(windowIndex: windowIndex, window: window, defaultPositionProjection: defaultPositionProjection)
            window.id = 0
            return window
        }

        func periodCount() -> Int {
            delegate.periodCount()
        }

        @discardableResult
        func getPeriod(periodIndex: Int, period: Period, setIds: Bool) -> Period {
            delegate.getPeriod(periodIndex: periodIndex, period: period, setIds: setIds)
            period.uid = 0
            return period
        }

        func indexOfPeriod(by id: AnyHashable) -> Int? {
            delegate.indexOfPeriod(by: id)
        }

        func id(for periodIndex: Int) -> AnyHashable { 0 }
    }
}
