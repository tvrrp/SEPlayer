//
//  TextOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//

import SEPlayerCommon

/// Receives text output.
public protocol TextOutput: AnyObject {
    /// Called when there is a change in the `CueGroup`.
    ///
    /// Called on the main queue.
    func onCues(_ cueGroup: CueGroup)
}
