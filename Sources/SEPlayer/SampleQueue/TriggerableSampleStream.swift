//
//  TriggerableSampleStream.swift
//  SEPlayer
//
//  Created by tvrrp on 15.03.2026.
//

import SEPlayerCommon

public protocol TriggerableSampleStream: SampleStream {
    /// Installs a trigger.
    ///
    /// If the condition is already true, `body` is called immediately before
    /// this method returns. The returned token can be used with `testTrigger`
    /// and `removeTrigger`; it is safe to discard if neither is needed.
    @discardableResult
    func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken
    /// Removes a previously installed trigger.
    func removeTrigger(_ token: QueueTriggerToken)
    /// Returns the current (level) state of the condition — no side effects.
    /// Returns false if the token is not installed on this queue.
    func testTrigger(_ token: QueueTriggerToken) -> Bool
}

public extension TriggerableSampleStream {
    @discardableResult
    func installTrigger(condition: TriggerCondition) -> QueueTriggerToken {
        installTrigger(condition: condition, nil)
    }
}
