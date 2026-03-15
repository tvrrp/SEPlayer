//
//  MediaChunkIterator.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import DataSource

public protocol MediaChunkIterator {
    var isEnded: Bool { get }
    var dataSpec: DataSpec? { get }
    var chunkStartTimeUs: Int64? { get }
    var chunkEndTimeUs: Int64? { get }
    func next() throws -> Bool
    func reset()
}

struct EmptyMediaChunkIterator: MediaChunkIterator {
    let isEnded = true
    let dataSpec: DataSpec? = nil
    let chunkStartTimeUs: Int64? = nil
    let chunkEndTimeUs: Int64? = nil

    func next() throws -> Bool { false }
    func reset() {}
}
