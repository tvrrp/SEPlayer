//
//  LoadingInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

struct LoadingInfo: Hashable {
    let playbackPosition: Int64
    let playbackSpeed: Float
    let lastRebufferRealtime: Int64

    func rebufferedSince(realtime: Int64) -> Bool {
        return lastRebufferRealtime != .timeUnset
            && realtime != .timeUnset
            && lastRebufferRealtime >= realtime
    }
}
