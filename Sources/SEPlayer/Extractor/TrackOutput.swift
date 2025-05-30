//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMFormatDescription

public protocol TrackOutput {
    func setFormat(_ format: CMFormatDescription)
    func loadSampleData(input: DataReader, length: Int, completionQueue: Queue, completion: @escaping (Result<Int, Error>) -> Void)
    func sampleMetadata(time: Int64, flags: SampleFlags, size: Int, offset: Int)
}
