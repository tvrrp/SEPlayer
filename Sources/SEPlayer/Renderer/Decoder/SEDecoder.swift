//
//  Decoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 21.04.2025.
//

protocol SEDecoder: AnyObject {
    associatedtype OutputBuffer: DecoderOutputBuffer
    func dequeueInputBufferIndex() -> Int?
    func dequeueInputBuffer(for index: Int) -> UnsafeMutableRawPointer
    func queueInputBuffer(for index: Int, inputBuffer: DecoderInputBuffer) throws

    func dequeueOutputBuffer() -> OutputBuffer?
    func flush()
    func release()
}
