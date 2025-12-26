//
//  RendererMessage.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.12.2025.
//

public enum RendererMessage {
    case requestMediaDataWhenReady(queue: Queue, block: () -> Void)
    case stopRequestingMediaData
    case setVideoOutput(_ output: PlayerBufferable)
    case removeVideoOutput(_ output: PlayerBufferable)
    case setAudioVolume(_ volume: Float)
    case setAudioIsMuted(_ isMuted: Bool)
}
