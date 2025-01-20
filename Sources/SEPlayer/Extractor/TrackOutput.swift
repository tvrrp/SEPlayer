//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol TrackOutput {
    func sampleData(input: DataReader, allowEndOfInput: Bool, metadata: SampleMetadata, completionQueue: Queue, completion: @escaping (Error?) -> Void)
}

struct SampleMetadata {
    let sampleTimings: CMSampleTimingInfo
    let flags: SampleFlags
    let size: Int

    init(duration: CMTime, presentationTimeStamp: CMTime, decodeTimeStamp: CMTime, flags: SampleFlags, size: Int) {
        self.sampleTimings = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
        self.flags = flags
        self.size = size
    }
}
