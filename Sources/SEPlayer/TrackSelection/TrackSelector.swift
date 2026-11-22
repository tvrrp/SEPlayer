//
//  TrackSelector.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.trackselection.TrackSelector
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreGraphics
import SEPlayerCommon

/// When a new track selection takes effect on media that is already buffered.
public enum TrackSelectionApplication: Sendable {
    /// Media loaded from now on uses the new selection; what is buffered plays out first, so playback goes on
    /// uninterrupted.
    case deferred
    /// Buffered media of a changed selection is replaced right away. Playback waits for the new media, showing the
    /// last picture meanwhile.
    case immediate
}

public class TrackSelector {
    public protocol Factory {
        func createTrackSelector() -> TrackSelector
    }

    public protocol InvalidationListener: AnyObject {
        func onTrackSelectionsInvalidated(application: TrackSelectionApplication)
        func onRendererCapabilitiesChanged(_ renderer: SERenderer)
    }

    public var bandwidthMeter: BandwidthMeter!
    private weak var listener: InvalidationListener?

    /// Binds the selector to its player. A selector serves one player: its parameters and invalidations are that
    /// player's, and the player's release unbinds it.
    public func initialize(listener: InvalidationListener, bandwidthMeter: BandwidthMeter) {
        assert(self.listener == nil || self.listener === listener, "A track selector can't be shared between players")
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
        fatalError("To override")
    }

    public func onSelectionActivated(info: Any?) {}
    public func getParameters() -> TrackSelectionParameters { .defaultParameters }
    public func setParameters(_ parameters: TrackSelectionParameters) {}
    /// Sets the parameters, applying the selections they change as `application` says.
    public func setParameters(_ parameters: TrackSelectionParameters, application: TrackSelectionApplication) {
        setParameters(parameters)
    }

    public func isSetParametersSupported() -> Bool { false }
    /// Takes the size the video output shows the picture at, in pixels, or `nil` without one, for the viewport.
    public func setVideoOutputSize(_ size: CGSize?) {}

    public func getRendererCapabilitiesListener() -> RendererCapabilitiesListener? {
        nil
    }

    /// Asks for the tracks to be selected again.
    ///
    /// - Parameter application: When a changed selection replaces what is buffered. Changes the player makes on its
    ///   own, as for a new device state, are deferred so playback isn't interrupted.
    public final func invalidate(application: TrackSelectionApplication = .deferred) {
        listener?.onTrackSelectionsInvalidated(application: application)
    }

    public final func invalidateForRendererCapabilitiesChange(_ renderer: SERenderer) {
        listener?.onRendererCapabilitiesChanged(renderer)
    }
}
