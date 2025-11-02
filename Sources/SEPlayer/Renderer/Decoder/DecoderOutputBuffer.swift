//
//  DecoderOutputBuffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

public protocol DecoderOutputBuffer {
    var sampleFlags: SampleFlags { get }
    var presentationTime: Int64 { get }
}
