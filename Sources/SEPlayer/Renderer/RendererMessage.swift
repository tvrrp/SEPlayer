//
//  RendererMessage.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.12.2025.
//

import CoreMedia
import SEPlayerCommon

public enum RendererMessage {
    case requestMediaDataWhenReady(queue: Queue, block: () -> Void)
    case stopRequestingMediaData
    case setVideoOutput(_ output: any VideoOutput)
    case removeVideoOutput(_ output: any VideoOutput)
    case setControlTimebase(_ timebase: CMTimebase?)
    case setAudioVolume(_ volume: Float)
    case setAudioIsMuted(_ isMuted: Bool)
}
