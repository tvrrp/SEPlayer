//
//  EmptySampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.05.2025.
//

import CoreMedia
import Decoder

final class EmptySampleStream: TriggerableSampleStream {
    func isReady() -> Bool { true }
    func maybeThrowError() throws {}

    func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult {
        buffer.flags.insert(.endOfStream)
        return .didReadBuffer
    }

    func skipData(position: CMTime) -> Int { .zero }

    func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken {
        QueueTriggerToken()
    }

    func removeTrigger(_ token: QueueTriggerToken) {}
    func testTrigger(_ token: QueueTriggerToken) -> Bool { false }
}

final class EmptySampleStream2: SampleStream2 {
    func isReady() -> Bool { true }
    func maybeThrowError() throws {}

    func readData(readFlags: ReadFlags) throws -> SampleStreamReadResult2 {
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
