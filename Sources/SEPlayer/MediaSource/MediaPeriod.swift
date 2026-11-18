//
//  MediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public protocol MediaPeriod: SequenceableLoader, AnyObject {
    var trackGroups: TrackGroupArray { get }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime)
    func maybeThrowPrepareError() throws
    func discardBuffer(position: CMTime, toKeyframe: Bool) throws
    func readDiscontinuity() -> CMTime
    func seek(position: CMTime) throws -> CMTime
    /// Recovery must not silently rewind an unseekable source to its beginning.
    func seekForRecovery(position: CMTime) throws -> CMTime
    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime
    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        position: CMTime
    ) throws -> CMTime
    /// Whether a stream goes on serving a new selection of its own track group in `selectTrack`, replacing what it
    /// buffered rather than being replaced itself.
    var keepsStreamsForSelectionsInSameGroup: Bool { get }
    /// Gives the streams new selections of the same track groups, keeping what they buffered: only what loads from now
    /// on follows the new selections.
    ///
    /// - Returns: `false` if that isn't possible, as for a selection of another group; nothing changed then.
    func updateSelectionsKeepingBuffer(_ selections: [SETrackSelection?], streams: [SampleStream?]) -> Bool
    /// Tells the period that seeks only need to show the frame at their position, as while the user scrubs a paused
    /// player with seeks that may land near the position. The period may then load less than playback would need, as
    /// the keyframe alone. The seek after scrubbing ends loads what playback needs again.
    func setScrubbing(_ isScrubbing: Bool)
}

public extension MediaPeriod {
    func seekForRecovery(position: CMTime) throws -> CMTime {
        throw RendererRecoveryError.positionUnavailable
    }

    var keepsStreamsForSelectionsInSameGroup: Bool { false }

    func updateSelectionsKeepingBuffer(_ selections: [SETrackSelection?], streams: [SampleStream?]) -> Bool {
        false
    }

    func setScrubbing(_ isScrubbing: Bool) {}
}

public protocol MediaPeriodCallback: SequenceableLoaderCallback where Source == any MediaPeriod {
    func didPrepare(mediaPeriod: any MediaPeriod)
}
