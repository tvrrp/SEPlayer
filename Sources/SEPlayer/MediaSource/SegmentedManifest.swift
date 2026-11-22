//
//  SegmentedManifest.swift
//  SEPlayer
//

import CoreMedia

/// The manifest of a stream played in segments, such as HLS, with what the load control starts playback with.
public protocol SegmentedManifest {
    /// The longest duration of a segment.
    var targetSegmentDuration: CMTime { get }
    /// The buffer a low-latency stream starts playing with, or `nil` if the stream isn't low latency.
    var lowLatencyStartBuffer: CMTime? { get }
}
