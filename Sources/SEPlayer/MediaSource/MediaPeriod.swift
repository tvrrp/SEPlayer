//
//  MediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public protocol MediaPeriod: SequenceableLoader, AnyObject {
    var trackGroups: TrackGroupArray { get }

    func prepare(callback: any MediaPeriodCallback, on time: Int64)
    func maybeThrowPrepareError() throws
    func discardBuffer(to position: Int64, toKeyframe: Bool)
    func readDiscontinuity() -> Int64
    func seek(to position: Int64) -> Int64
    func getAdjustedSeekPositionUs(positionUs: Int64, seekParameters: SeekParameters) -> Int64
    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        positionUs: Int64
    ) -> Int64
}

public protocol MediaPeriodCallback: SequenceableLoaderCallback where Source == any MediaPeriod {
    func didPrepare(mediaPeriod: any MediaPeriod)
}
