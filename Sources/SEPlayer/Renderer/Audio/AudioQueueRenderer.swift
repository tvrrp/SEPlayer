//
//  AudioQueueRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.04.2025.
//

import AudioToolbox
import CoreMedia

protocol AQDecoder: SEDecoder where OutputBuffer: AQOutputBuffer {
    static func getCapabilities() -> RendererCapabilities
    func canReuseDecoder(oldFormat: CMFormatDescription?, newFormat: CMFormatDescription) -> Bool
}

protocol AQOutputBuffer: DecoderOutputBuffer {
    var audioBuffer: CMSampleBuffer { get }
}

final class AudioQueueRenderer {
    
}
