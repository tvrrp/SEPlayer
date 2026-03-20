//
//  LoadingInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

import CoreMedia

public struct LoadingInfo: Hashable {
    let playbackPosition: CMTime
    let playbackSpeed: Float
    let lastRebufferRealtime: CMTime

    func rebufferedSince(realtime: CMTime) -> Bool {
        return lastRebufferRealtime.isValid
            && realtime.isValid
            && lastRebufferRealtime >= realtime
    }
}
