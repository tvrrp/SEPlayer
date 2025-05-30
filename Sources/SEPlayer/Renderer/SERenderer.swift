//
//  SERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import CoreMedia.CMFormatDescription

protocol SERenderer: AnyObject {
    var trackType: TrackType { get }
    func getCapabilities() -> RendererCapabilities

    func getMediaClock() -> MediaClock?
    func getState() -> SERendererState
    func enable(
        formats: [CMFormatDescription],
        stream: SampleStream,
        position: Int64,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: Int64,
        offset: Int64,
        mediaPeriodId: MediaPeriodId
    ) throws

    func start() throws

    func replaceStream(
        formats: [CMFormatDescription],
        stream: SampleStream,
        startPosition: Int64,
        offset: Int64,
        mediaPeriodId: MediaPeriodId
    ) throws
    func getStream() -> SampleStream?
    func didReadStreamToEnd() -> Bool
    func getReadingPosition() -> Int64
    func setStreamFinal()
    func isCurrentStreamFinal() -> Bool
    func resetPosition(new position: Int64) throws
    func setPlaybackSpeed(current: Float, target: Float) throws
    func enableRenderStartOfStream()
    func getTimeline() -> Timeline
    func setTimeline(_ timeline: Timeline)
    func render(position: Int64, elapsedRealtime: Int64) throws
    func isReady() -> Bool
    func isEnded() -> Bool
    func stop()
    func disable()
    func reset()
    func release()
}

enum SERendererState {
    case disabled
    case enabled
    case started
}
