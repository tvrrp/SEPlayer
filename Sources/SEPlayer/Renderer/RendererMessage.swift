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
    /// What the renderer plays to; `nil` detaches it.
    case setTimeSource(_ source: RendererTimeSource?)
    case setAudioVolume(_ volume: Float)
    case setAudioIsMuted(_ isMuted: Bool)
    /// Scoped to recovery; ordinary disable/release still removes the displayed image.
    case setPreservesDisplayedImageOnDisable(Bool)
}
