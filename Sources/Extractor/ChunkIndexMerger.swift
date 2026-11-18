//
//  ChunkIndexMerger.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.08.2026.
//

import CoreMedia
import OrderedCollections
import SEPlayerCommon

struct ChunkIndexMerger {
    var count: Int { chunkMap.count }

    private var chunkMap = OrderedDictionary<CMTime, ChunkIndex>()

    mutating func add(_ chunk: ChunkIndex) {
        if !chunk.times.isEmpty, !chunkMap.keys.contains(chunk.times[0]) {
            chunkMap[chunk.times[0]] = chunk
        }
    }

    func merge() -> ChunkIndex {
        ChunkIndex(
            sizes: chunkMap.values.flatMap { $0.sizes },
            offsets: chunkMap.values.flatMap { $0.offsets },
            durations: chunkMap.values.flatMap { $0.durations },
            times: chunkMap.values.flatMap { $0.times }
        )
    }

    mutating func clear() {
        chunkMap.removeAll()
    }
}
