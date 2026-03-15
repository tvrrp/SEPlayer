//
//  MediaChunk.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import DataSource
import SEPlayerCommon

public class MediaChunk: Chunk {
    var nextChunkIndex: Int? {
        if let chunkIndex { chunkIndex + 1 } else { nil }
    }

    public let chunkIndex: Int?

    public init(
        dataSource: DataSource,
        dataSpec: DataSpec,
        trackFormat: Format,
        trackSelectionReason: TrackSelectionReason,
        trackSelectionData: Any?,
        startTimeUs: Int64,
        endTimeUs: Int64,
        chunkIndex: Int?
    ) {
        self.chunkIndex = chunkIndex

        super.init(
            dataSource: dataSource,
            dataSpec: dataSpec,
            dataType: Void(),
            trackFormat: trackFormat,
            trackSelectionReason: trackSelectionReason,
            trackSelectionData: trackSelectionData,
            startTimeUs: startTimeUs,
            endTimeUs: endTimeUs
        )
    }

    func isLoadCompleted() -> Bool { fatalError() }
}
