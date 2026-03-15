//
//  LoadEventInfo.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import DataSource
import Foundation
import SEPlayerCommon

struct LoadEventInfo: @unchecked Sendable {
    let loadTaskId: Int
    let dataSpec: DataSpec
    let url: URL
    let responseHeaders: URLResponse
    let elapsedRealtimeMs: Int64
    let loadDurationMs: Int64
    let bytesLoaded: Int

    private static var idSource = 0
    private static let lock = UnfairLock()

    init(
        loadTaskId: Int,
        dataSpec: DataSpec,
        url: URL,
        responseHeaders: URLResponse,
        elapsedRealtimeMs: Int64,
        loadDurationMs: Int64 = .zero,
        bytesLoaded: Int = .zero
    ) {
        self.loadTaskId = loadTaskId
        self.dataSpec = dataSpec
        self.url = url
        self.responseHeaders = responseHeaders
        self.elapsedRealtimeMs = elapsedRealtimeMs
        self.loadDurationMs = loadDurationMs
        self.bytesLoaded = bytesLoaded
    }

    static func nextLoadId() -> Int {
        lock.withLock {
            let current = idSource
            idSource += 1
            return current
        }
    }

    func copyWithTaskIdAndDurationMs(_ loadTaskId: Int, loadDurationMs: Int64) -> LoadEventInfo {
        LoadEventInfo(
            loadTaskId: loadTaskId,
            dataSpec: dataSpec,
            url: url,
            responseHeaders: responseHeaders,
            elapsedRealtimeMs: elapsedRealtimeMs,
            loadDurationMs: loadDurationMs,
            bytesLoaded: bytesLoaded
        )
    }
}
