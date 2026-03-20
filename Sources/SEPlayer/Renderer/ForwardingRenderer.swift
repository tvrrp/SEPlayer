//
//  ForwardingRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.12.2025.
//

import CoreMedia
import SEPlayerCommon

open class ForwardingRenderer: SERenderer {
    open var trackType: TrackType { renderer.trackType }

    open var delegate: SERendererDelegate? {
        get { renderer.delegate }
        set { renderer.delegate = newValue }
    }

    private let renderer: SERenderer

    public init(renderer: SERenderer) {
        self.renderer = renderer
    }

    open func getCapabilities() -> RendererCapabilitiesResolver {
        renderer.getCapabilities()
    }

    open func handleMessage(_ message: RendererMessage) throws {
        try renderer.handleMessage(message)
    }

    open func getMediaClock() -> MediaClock? {
        renderer.getMediaClock()
    }

    open func getTimebase() -> CMTimebase? {
        renderer.getTimebase()
    }

    open func getState() -> SERendererState {
        renderer.getState()
    }

    open func enable(
        formats: [Format],
        stream: TriggerableSampleStream,
        position: CMTime,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: CMTime,
        offset: CMTime,
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

    open func start() throws {
        try renderer.start()
    }

    open func replaceStream(
        formats: [Format],
        stream: TriggerableSampleStream,
        startPosition: CMTime,
        offset: CMTime,
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

    open func getStream() -> TriggerableSampleStream? {
        renderer.getStream()
    }

    open func didReadStreamToEnd() -> Bool {
        renderer.didReadStreamToEnd()
    }

    open func getReadingPosition() -> CMTime {
        renderer.getReadingPosition()
    }

    open func setStreamFinal() {
        renderer.setStreamFinal()
    }

    open func isCurrentStreamFinal() -> Bool {
        renderer.isCurrentStreamFinal()
    }

    open func resetPosition(new position: CMTime) throws {
        try renderer.resetPosition(new: position)
    }

    open func setPlaybackSpeed(current: Float, target: Float) throws {
        try renderer.setPlaybackSpeed(current: current, target: target)
    }

    open func enableRenderStartOfStream() {
        renderer.enableRenderStartOfStream()
    }

    open func getTimeline() -> Timeline {
        renderer.getTimeline()
    }

    open func setTimeline(_ timeline: Timeline) {
        renderer.setTimeline(timeline)
    }

    open func render(position: CMTime, elapsedRealtime: CMTime) throws {
        try renderer.render(position: position, elapsedRealtime: elapsedRealtime)
    }

    open func isReady() -> Bool {
        renderer.isReady()
    }

    open func isEnded() -> Bool {
        renderer.isEnded()
    }

    open func stop() {
        renderer.stop()
    }

    open func disable() {
        renderer.disable()
    }

    open func reset() {
        renderer.reset()
    }

    open func release() {
        renderer.release()
    }
}
