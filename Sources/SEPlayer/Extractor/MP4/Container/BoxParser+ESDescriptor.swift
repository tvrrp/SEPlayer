//
//  BoxParser+ESDescriptor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import AudioToolbox.AudioFormat
import CoreMedia.CMFormatDescription

extension BoxParser {
    struct ESDescriptor {
        let codecInfo: CMAudioFormatDescription?

        init(esdt payload: Data) throws {
            var description = AudioStreamBasicDescription()
            var size = Int32(MemoryLayout<AudioStreamBasicDescription>.size)
            let propertyID = kAudioFormatProperty_ASBDFromESDS

            try! payload.withUnsafeBytes { pointer in
                return AudioFormatGetProperty(
                    propertyID,
                    UInt32(payload.count),
                    pointer.baseAddress,
                    &size,
                    &description
                )
            }.validate()

            codecInfo = try! CMAudioFormatDescription(audioStreamBasicDescription: description)
        }
    }
}
