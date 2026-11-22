//
//  SERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.Renderer
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import AVFoundation
import SEPlayerCommon
import VideoToolbox

public protocol SERendererDelegate: AnyObject {
    func rendererFinishedPreroll(_ renderer: SERenderer)
    func rendererPipelineStalled(_ renderer: SERenderer)
    func rendererDidFinishReading(_ renderer: SERenderer)
    func rendererDidFinishRendering(_ renderer: SERenderer)
    func onRendererError(_ renderer: SERenderer, error: SEPlaybackError)
    func rendererNeedsRecovery(_ renderer: SERenderer, request: RendererRecoveryRequest)
    /// Called when playback really started after the renderer was started: the clock began to move. A synchronizer
    /// can hold the clock after its rate is set, until its renderers have enough media data.
    func rendererDidStartPlayback(_ renderer: SERenderer)
    /// Called when the renderer shows a frame after it was reset, before it may have enough media to play.
    func rendererDidPresentOutput(_ renderer: SERenderer)
}

public extension SERendererDelegate {
    func rendererDidStartPlayback(_ renderer: SERenderer) {}
    func rendererDidPresentOutput(_ renderer: SERenderer) {}
}

public extension SERenderer {
    func hasPresentedOutput() -> Bool { false }
}

public protocol SERenderer: AnyObject {
    var trackType: TrackType { get }
    var delegate: SERendererDelegate? { get set }
    func handleMessage(_ message: RendererMessage) throws
    func getCapabilities() -> RendererCapabilitiesResolver

    func getMediaClock() -> MediaClock?
    func getTimebase() -> CMTimebase?
    /// The synchronizer the renderer plays through, which the video joins; `nil` for none.
    func getRenderSynchronizer() -> (any PlaybackSynchronizer)?
    func getState() -> SERendererState
    func getRecoveryContext() -> RendererRecoveryContext
    var isRecoveringWhileTimelineAdvances: Bool { get }
    func recoverOutput(at position: CMTime, reason: RendererRecoveryReason) throws -> Bool
    func enable(
        formats: [AnyFormat],
        stream: SampleStream,
        position: CMTime,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId,
        delegate: any SERendererDelegate
    ) throws

    func start() throws

    func replaceStream(
        formats: [AnyFormat],
        stream: SampleStream,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws
    func getStream() -> SampleStream?
    func didReadStreamToEnd() -> Bool
    func getReadingPosition() -> CMTime
    func setStreamFinal()
    func isCurrentStreamFinal() -> Bool
    func resetPosition(new position: CMTime) throws
    func setPlaybackSpeed(current: Float, target: Float) throws
    func enableRenderStartOfStream()
    func getTimeline() -> Timeline
    func setTimeline(_ timeline: Timeline)
    func render(position: CMTime, elapsedRealtime: CMTime) throws
    func isReady() -> Bool
    func isEnded() -> Bool
    /// Whether the renderer has presented output of its stream since it was last reset, as a video renderer that
    /// shows the frame at the position. A paused seek is done then.
    func hasPresentedOutput() -> Bool
    func stop()
    func disable()
    func reset()
    func release()
}

@frozen
public enum SERendererState {
    case disabled
    case enabled
    case started
}

enum CodecInputRequestResult<T> {
    case haveData(buffer: T, isRealtime: Bool, shouldDrop: Bool)
    case noDataNow
    case endOfStream
}

enum CodecOutputStatus {
    case haveData
    case inputRanDry
    case endOfStream
}
