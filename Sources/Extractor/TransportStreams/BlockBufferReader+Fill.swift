//
//  BlockBufferReader+Fill.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.11.2026.
//

import SEPlayerCommon

extension BlockBufferReader {
    /// Appends bytes of `source` to this buffer until it holds `targetLength`, and moves `source` past them.
    ///
    /// - Returns: Whether the buffer holds `targetLength` bytes.
    func fill(from source: inout BlockBufferReader, upTo targetLength: Int) throws -> Bool {
        let bytesToRead = Swift.min(source.readableBytes, targetLength - capacity)
        if bytesToRead > 0 {
            try extend(with: source.readSlice(length: bytesToRead))
        }
        return capacity >= targetLength
    }
}
