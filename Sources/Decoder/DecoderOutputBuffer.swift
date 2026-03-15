//
//  DecoderOutputBuffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

import SEPlayerCommon

public protocol DecoderOutputBuffer {
    var sampleFlags: SampleFlags { get }
    var timeUs: Int64 { get }
    var skippedOutputBufferCount: Int { get }
    var shouldBeSkipped: Bool { get }
    func release()
    func clear()
}
