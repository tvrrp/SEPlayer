//
//  SERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import CoreMedia
import SEPlayerCommon

public protocol SERendererDelegate: AnyObject {
    func rendererReportsReady(_ renderer: SERenderer)
    func rendererNeedsMoreData(_ renderer: SERenderer)
    func rendererDidFinishReading(_ renderer: SERenderer)
    func rendererDidFinishRendering(_ renderer: SERenderer)
    func onRendererError(_ renderer: SERenderer, error: SEPlaybackError)
}

public protocol SERenderer: AnyObject {
    var trackType: TrackType { get }
    var delegate: SERendererDelegate? { get set }
    func handleMessage(_ message: RendererMessage) throws
    func getCapabilities() -> RendererCapabilitiesResolver

    func getMediaClock() -> MediaClock?
    func getTimebase() -> CMTimebase?
    func getState() -> SERendererState
    func enable(
        formats: [Format],
        stream: TriggerableSampleStream,
        position: CMTime,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws

    func start() throws

    func replaceStream(
        formats: [Format],
        stream: TriggerableSampleStream,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws
    func getStream() -> TriggerableSampleStream?
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
