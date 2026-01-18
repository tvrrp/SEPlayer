//
//  TestDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.12.2025.
//

import Foundation

protocol Decoder {
    associatedtype InputBuffer
    associatedtype OutputBuffer
    associatedtype DecoderError: Error

    func setOutputStartTimeUs(_ outputStartTimeUs: Int64)
    func setPlaybackSpeed(_ speed: Float)
    func dequeueInputBuffer() throws(DecoderError) -> InputBuffer?
    func queueInputBuffer(_ inputBuffer: InputBuffer) throws(DecoderError)
    func dequeueOutputBuffer() throws(DecoderError) -> OutputBuffer?
    func flush()
    func release()
}
