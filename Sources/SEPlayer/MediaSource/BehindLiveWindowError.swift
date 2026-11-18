//
//  BehindLiveWindowError.swift
//  SEPlayer
//

import SEPlayerCommon

/// Thrown when playback falls behind the window of a live stream: the media it needs is no longer available.
///
/// Playback recovers by seeking to the default position of the window and preparing again.
public struct BehindLiveWindowError: PlaybackErrorCodeProviding {
    public var errorCode: PlaybackErrorCode { .behindLiveWindow }

    public init() {}
}
