//
//  Chunk.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import CoreMedia
import DataSource
import Foundation
import SEPlayerCommon

/// An abstract base class for ``Loadable`` implementations that load chunks of data required for the playback of
/// streams.
open class Chunk: Loadable, @unchecked Sendable {
    /// Identifies the load task for this loadable.
    public let loadTaskId: Int
    /// The data spec that defines the data to be loaded.
    public let dataSpec: DataSpec
    /// The data type of the chunk.
    public let dataType: DataType
    /// The format of the track to which this chunk belongs.
    public let trackFormat: AnyFormat?
    /// One of the selection reasons if the chunk belongs to a track.
    public let trackSelectionReason: TrackSelectionReason
    /// Optional data associated with the selection of the track to which this chunk belongs.
    public let trackSelectionData: Any?
    /// The start time of the media contained by the chunk, or `.invalid` if the data being loaded does not contain
    /// media samples.
    public let startTime: CMTime
    /// The end time of the media contained by the chunk, or `.invalid` if the data being loaded does not contain
    /// media samples.
    public let endTime: CMTime

    /// The duration of the media contained by the chunk.
    public var duration: CMTime { endTime - startTime }

    /// The number of bytes that have been loaded.
    public var bytesLoaded: Int { bytesLock.withLock { _bytesLoaded } }

    private let bytesLock = UnfairLock()
    private var _bytesLoaded = 0 // guarded by bytesLock

    public init(
        dataSpec: DataSpec,
        dataType: DataType,
        trackFormat: AnyFormat?,
        trackSelectionReason: TrackSelectionReason,
        trackSelectionData: Any?,
        startTime: CMTime,
        endTime: CMTime
    ) {
        self.dataSpec = dataSpec
        self.dataType = dataType
        self.trackFormat = trackFormat
        self.trackSelectionReason = trackSelectionReason
        self.trackSelectionData = trackSelectionData
        self.startTime = startTime
        self.endTime = endTime
        loadTaskId = LoadEventInfo.nextLoadId()
    }

    open func load(_ isolation: isolated any Actor) async throws {
        fatalError("To override")
    }

    /// Counts loaded bytes.
    public final func addBytesLoaded(_ count: Int) {
        bytesLock.withLock { _bytesLoaded += count }
    }
}
