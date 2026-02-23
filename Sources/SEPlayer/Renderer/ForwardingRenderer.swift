//
//  ForwardingRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.12.2025.
//

import CoreMedia

public class ForwardingRenderer: SERenderer {
    public var trackType: TrackType { renderer.trackType }

    private let renderer: SERenderer

    public init(renderer: SERenderer) {
        self.renderer = renderer
    }

    public func getCapabilities() -> RendererCapabilitiesResolver {
        renderer.getCapabilities()
    }

    public func handleMessage(_ message: RendererMessage) throws {
        try renderer.handleMessage(message)
    }

    public func getMediaClock() -> MediaClock? {
        renderer.getMediaClock()
    }

    public func getTimebase() -> CMTimebase? {
        renderer.getTimebase()
    }

    public func getState() -> SERendererState {
        renderer.getState()
    }

    public func enable(
        formats: [Format],
        stream: SampleStream,
        position: Int64,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: Int64,
        offset: Int64,
        mediaPeriodId: MediaPeriodId
    ) throws {
        try renderer.enable(
            formats: formats,
            stream: stream,
            position: position,
            joining: joining,
            mayRenderStartOfStream: mayRenderStartOfStream,
            startPosition: startPosition,
            offset: offset,
            mediaPeriodId: mediaPeriodId
        )
    }

    public func start() throws {
        try renderer.start()
    }

    public func replaceStream(
        formats: [Format],
        stream: SampleStream,
        startPosition: Int64,
        offset: Int64,
        mediaPeriodId: MediaPeriodId
    ) throws {
        try renderer.replaceStream(
            formats: formats,
            stream: stream,
            startPosition: startPosition,
            offset: offset,
            mediaPeriodId: mediaPeriodId
        )
    }

    public func getStream() -> SampleStream? {
        renderer.getStream()
    }

    public func didReadStreamToEnd() -> Bool {
        renderer.didReadStreamToEnd()
    }

    public func getReadingPosition() -> Int64 {
        renderer.getReadingPosition()
    }

    public func setStreamFinal() {
        renderer.setStreamFinal()
    }

    public func isCurrentStreamFinal() -> Bool {
        renderer.isCurrentStreamFinal()
    }

    public func resetPosition(new position: Int64) throws {
        try renderer.resetPosition(new: position)
    }

    public func setPlaybackSpeed(current: Float, target: Float) throws {
        try renderer.setPlaybackSpeed(current: current, target: target)
    }

    public func enableRenderStartOfStream() {
        renderer.enableRenderStartOfStream()
    }

    public func getTimeline() -> Timeline {
        renderer.getTimeline()
    }

    public func setTimeline(_ timeline: Timeline) {
        renderer.setTimeline(timeline)
    }

    public func render(position: Int64, elapsedRealtime: Int64) throws {
        try renderer.render(position: position, elapsedRealtime: elapsedRealtime)
    }

    public func isReady() -> Bool {
        renderer.isReady()
    }

    public func isEnded() -> Bool {
        renderer.isEnded()
    }

    public func stop() {
        renderer.stop()
    }

    public func disable() {
        renderer.disable()
    }

    public func reset() {
        renderer.reset()
    }

    public func release() {
        renderer.release()
    }
}
