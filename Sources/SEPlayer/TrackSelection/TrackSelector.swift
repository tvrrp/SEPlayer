//
//  TrackSelector.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//

import SEPlayerCommon

public class TrackSelector {
    public protocol Factory {
        func createTrackSelector() -> TrackSelector
    }

    public protocol InvalidationListener: AnyObject {
        func onTrackSelectionsInvalidated()
        func onRendererCapabilitiesChanged(_ renderer: SERenderer)
    }

    public var bandwidthMeter: BandwidthMeter!
    private weak var listener: InvalidationListener?

    public func initialize(listener: InvalidationListener, bandwidthMeter: BandwidthMeter) {
        self.listener = listener
        self.bandwidthMeter = bandwidthMeter
    }

    public func release() {
        self.listener = nil
        self.bandwidthMeter = nil
    }

    public func selectTracks(
        rendererCapabilities: [RendererCapabilitiesResolver],
        trackGroups: TrackGroupArray,
        periodId: MediaPeriodId,
        timeline: Timeline
    ) throws -> TrackSelectorResult {
        fatalError()
    }

    public func onSelectionActivated(info: Any?) {}
    public func getParameters() -> TrackSelectionParameters { .defaultParameters }
    public func setParameters(_ parameters: TrackSelectionParameters) {}
    public func isSetParametersSupported() -> Bool { false }

    public func getRendererCapabilitiesListener() -> RendererCapabilitiesListener? {
        nil
    }

    public final func invalidate() {
        listener?.onTrackSelectionsInvalidated()
    }

    public final func invalidateForRendererCapabilitiesChange(_ renderer: SERenderer) {
        listener?.onRendererCapabilitiesChanged(renderer)
    }
}
