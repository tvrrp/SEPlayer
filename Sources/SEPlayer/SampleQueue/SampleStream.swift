//
//  SampleStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol SampleStream {
    var format: CMFormatDescription { get }
    func isReady() -> Bool
    func readData(to decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult
    func skipData(to time: CMTime) -> Int
}

enum SampleStreamReadResult {
    case nothingRead
    case didReadBuffer
}
