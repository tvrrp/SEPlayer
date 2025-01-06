//
//  MediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol MediaPeriod: SequenceableLoader {
    var trackGroups: Set<TrackGroup> { get }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime)
    func discardBuffer(to time: CMTime, toKeyframe: Bool)
    func seek(to time: CMTime)
    func selectTrack(selections: [Void], on time: CMTime) -> [SampleStream]
}

protocol MediaPeriodCallback: SequenceableLoaderCallback where Source == any MediaPeriod {
    func didPrepare(mediaPeriod: any MediaPeriod)
}
