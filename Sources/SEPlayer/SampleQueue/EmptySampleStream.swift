//
//  EmptySampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.EmptySampleStream
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

final class EmptySampleStream: SampleStream {
    var bufferedAheadDuration: CMTime { .invalid }

    func isReady() -> Bool { true }
    func maybeThrowError() throws {}

    func readData(readFlags: ReadFlags) throws -> SampleStreamReadResult {
        let sampleBuffer = try CMSampleBuffer.endOfStream()
        return .didReadBuffer(sampleBuffer)
    }

    func skipData(position: CMTime) throws -> Int { .zero }

    func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken {
        QueueTriggerToken()
    }

    func removeTrigger(_ token: QueueTriggerToken) {}
    func testTrigger(_ token: QueueTriggerToken) -> Bool { false }
}
