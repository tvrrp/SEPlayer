//
//  TestUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 03.11.2025.
//

import CoreMedia
@testable import SEPlayer

struct TestUtil {
    public static func buildTestData(lenght: Int) -> ByteBuffer {
        buildTestData(lenght: lenght, seed: lenght)
    }

    public static func buildTestData(lenght: Int, seed: Int) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.reserveCapacity(minimumWritableBytes: lenght)
        let seed: UInt8 = seed <= Int(UInt8.max) ? UInt8(seed) : UInt8.max

        for _ in 0..<lenght {
            let randomNumber = UInt8.random(in: 0..<seed)
            buffer.writeInteger(randomNumber)
        }

        return buffer
    }

    public static func timelinesAreSame(lhs: Timeline, rhs: Timeline) -> Bool {
        return NoIdOrShufflingTimeline(delegate: lhs)
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
