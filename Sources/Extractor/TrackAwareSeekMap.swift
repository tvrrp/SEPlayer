//
//  TrackAwareSeekMap.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

public protocol TrackAwareSeekMap: SeekMap {
    func isSeekable(trackId: Int) -> Bool
    func getSeekPoints(timeUs: Int64, trackId: Int?) -> SeekPoints
}
