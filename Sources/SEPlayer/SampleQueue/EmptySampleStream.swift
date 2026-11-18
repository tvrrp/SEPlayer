//
//  EmptySampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.05.2025.
//

import CoreMedia
import Decoder

final class EmptySampleStream: SampleStream {
    var bufferedAheadDuration: CMTime { .invalid }

    func isReady() -> Bool { true }
    func maybeThrowError() throws {}

    func readData(readFlags: ReadFlags) throws -> SampleStreamReadResult {
        let sampleBuffer = try CMSampleBuffer.createEndOfStream()
        return .didReadBuffer(sampleBuffer)
    }

    func skipData(position: CMTime) throws -> Int { .zero }

    func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken {
        QueueTriggerToken()
    }

    func removeTrigger(_ token: QueueTriggerToken) {}
    func testTrigger(_ token: QueueTriggerToken) -> Bool { false }
}
