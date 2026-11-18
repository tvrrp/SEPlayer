//
//  MediaChunk.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import CoreMedia
import DataSource
import SEPlayerCommon

/// An abstract base class for ``Chunk``s that contain media samples.
open class MediaChunk: Chunk, @unchecked Sendable {
    /// The chunk index, or `nil` if it is not known.
    public let chunkIndex: Int?

    /// The next chunk index, or `nil` if it is not known.
    open var nextChunkIndex: Int? {
        chunkIndex.map { $0 + 1 }
    }

    public init(
        dataSpec: DataSpec,
        trackFormat: Format,
        trackSelectionReason: TrackSelectionReason,
        trackSelectionData: Any?,
        startTime: CMTime,
        endTime: CMTime,
        chunkIndex: Int?
    ) {
        self.chunkIndex = chunkIndex
        super.init(
            dataSpec: dataSpec,
            dataType: .media,
            trackFormat: trackFormat,
            trackSelectionReason: trackSelectionReason,
            trackSelectionData: trackSelectionData,
            startTime: startTime,
            endTime: endTime
        )
    }

    /// Whether the chunk has been fully loaded.
    open var isLoadCompleted: Bool { fatalError("To override") }
}
