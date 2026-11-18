//
//  AudioRoute.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import AVFoundation

/// Where the audio plays.
enum AudioRoute {
    /// Whether the audio goes to AirPlay, which buffers a second or more before it plays.
    static var isAirPlay: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }
}
