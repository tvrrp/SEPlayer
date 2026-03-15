//
//  Chunk.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import DataSource
import Foundation
import SEPlayerCommon

public class Chunk: Loadable {
    public let loadTaskId: Int
    public let dataSpec: DataSpec
    public let dataType: Void // TODO: dataType
    public let trackFormat: Format
    public let trackSelectionReason: TrackSelectionReason
    public let trackSelectionData: Any?
    public let startTimeUs: Int64
    public let endTimeUs: Int64
    public let dataSource: StatsDataSource

    public var durationUs: Int64 { endTimeUs - startTimeUs }
    public var bytesLoaded: Int { dataSource.bytesRead }
    public var url: URL? { dataSource.lastOpenedUrl }
    public var urlResponse: URLResponse? { dataSource.lastUrlResponse }

    public init(
        dataSource: DataSource,
        dataSpec: DataSpec,
        dataType: Void,
        trackFormat: Format,
        trackSelectionReason: TrackSelectionReason,
        trackSelectionData: Any?,
        startTimeUs: Int64,
        endTimeUs: Int64
    ) {
        self.dataSource = StatsDataSource(dataSource: dataSource)
        self.dataSpec = dataSpec
        self.dataType = dataType
        self.trackFormat = trackFormat
        self.trackSelectionReason = trackSelectionReason
        self.trackSelectionData = trackSelectionData
        self.startTimeUs = startTimeUs
        self.endTimeUs = endTimeUs
        loadTaskId = LoadEventInfo.nextLoadId()
    }

    public func load(isolation: isolated any Actor) async throws {
        fatalError()
    }
}
