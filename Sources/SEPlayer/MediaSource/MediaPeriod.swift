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
    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime
    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream2?],
        streamResetFlags: inout [Bool],
        position: CMTime
    ) throws -> CMTime
}

public protocol MediaPeriodCallback: SequenceableLoaderCallback where Source == any MediaPeriod {
    func didPrepare(mediaPeriod: any MediaPeriod)
}
