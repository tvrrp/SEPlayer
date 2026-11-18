//
//  TestDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.12.2025.
//

import CoreMedia
import SEPlayerCommon

public protocol Decoder<InputBuffer, OutputBuffer, DecoderError>: AnyObject {
    associatedtype InputBuffer
    associatedtype OutputBuffer
    associatedtype DecoderError: Error

    var onInputBufferAvailable: (() -> Void)? { get set }
    func setOutputStartTime(_ outputStartTime: CMTime)
    func setPlaybackSpeed(_ speed: Float)
    func dequeueInputBuffer() throws(DecoderError) -> InputBuffer?
    func queueInputBuffer(_ inputBuffer: InputBuffer) throws(DecoderError)
    func dequeueOutputBuffer() throws(DecoderError) -> OutputBuffer?
    func flush()
    func release()

    /// Installs a trigger.
    ///
    /// If the condition is already true, `body` is called immediately before
    /// this method returns. The returned token can be used with `testTrigger`
    /// and `removeTrigger`; it is safe to discard if neither is needed.
    func installTrigger(condition: TriggerCondition, _ body: CMBufferQueueTriggerHandler?) throws -> CMBufferQueueTriggerToken
    /// Removes a previously installed trigger.
    func removeTrigger(_ triggerToken: CMBufferQueueTriggerToken) throws
    /// Returns the current (level) state of the condition — no side effects.
    /// Returns false if the token is not installed on this queue.
    func testTrigger(_ triggerToken: CMBufferQueueTriggerToken) -> Bool
}

public extension Decoder {
    func installTrigger(condition: TriggerCondition) throws -> CMBufferQueueTriggerToken {
        try installTrigger(condition: condition, nil)
    }
}
