//
//  MediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol MediaPeriod: SequenceableLoader, AnyObject {
    var trackGroups: [TrackGroup] { get }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime)
    func discardBuffer(to position: Int64, toKeyframe: Bool)
    func seek(to position: Int64)
    func selectTrack(selections: [any SETrackSelection], on time: CMTime) -> [SampleStream]
}

protocol MediaPeriodCallback: SequenceableLoaderCallback where Source == any MediaPeriod {
    func didPrepare(mediaPeriod: any MediaPeriod)
}
