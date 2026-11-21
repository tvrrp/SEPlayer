//
//  MetadataOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import SEPlayerCommon

/// Receives timed metadata: ID3 tags, ICY titles, event messages.
public protocol MetadataOutput: AnyObject {
    /// Called when the playback position reaches the time of `metadata`, its ``Metadata/presentationTime``.
    ///
    /// Called on the main queue.
    func onMetadata(_ metadata: Metadata)
}
