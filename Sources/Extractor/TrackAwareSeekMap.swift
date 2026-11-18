//
//  TrackAwareSeekMap.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

import CoreMedia

public protocol TrackAwareSeekMap: SeekMap {
    func isSeekable(trackId: Int) -> Bool
    func getSeekPoints(time: CMTime, trackId: Int?) -> SeekPoints
}
