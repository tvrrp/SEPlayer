//
//  Buffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import CoreMedia

protocol Buffer {
    var flags: SampleFlags { get }
}

final class DecoderInputBuffer: Buffer {
    let flags = SampleFlags()
    let format: CMFormatDescription?
    let data: CMBlockBuffer?

    let sampleMetadata: CMSampleTimingInfo

    init() {
        fatalError()
    }
}
