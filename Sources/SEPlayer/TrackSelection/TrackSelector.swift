//
//  TrackSelector.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//

public class TrackSelector {
    public protocol Factory {
        func createTrackSelector() -> TrackSelector
    }

    public protocol InvalidationListener: AnyObject {
        func onTrackSelectionsInvalidated()
        func onRendererCapabilitiesChanged(_ renderer: SERenderer)
    }

    var bandwidthMeter: BandwidthMeter!
    private weak var listener: InvalidationListener?

    func initialize(listener: InvalidationListener, bandwidthMeter: BandwidthMeter) {
        self.listener = listener
        self.bandwidthMeter = bandwidthMeter
    }

    func release() {
        self.listener = nil
        self.bandwidthMeter = nil
    }

    func selectTracks(
        rendererCapabilities: [RendererCapabilitiesResolver],
        trackGroups: TrackGroupArray,
        periodId: MediaPeriodId,
        timeline: Timeline
    ) throws -> TrackSelectorResult {
        fatalError()
    }

    func onSelectionActivated(info: Any?) {}
    func getParameters() -> TrackSelectionParameters { .defaultParameters }
    func setParameters(_ parameters: TrackSelectionParameters) {}
    func isSetParametersSupported() -> Bool { false }

    func getRendererCapabilitiesListener() -> RendererCapabilitiesListener? {
        nil
    }

    final func invalidate() {
        listener?.onTrackSelectionsInvalidated()
    }

    final func invalidateForRendererCapabilitiesChange(_ renderer: SERenderer) {
        listener?.onRendererCapabilitiesChanged(renderer)
    }
}
