//
//  FlacUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import SEPlayerCommon

/// Reads the FLAC decoder configuration: the `dfLa` box of a `fLaC` sample entry, with the stream's metadata blocks.
enum FlacUtil {
    /// The magic cookie of a `dfLa` box: the box itself, from its size field.
    static func magicCookie(dfLa box: BlockBufferReader) -> BlockBufferReader {
        box
    }

    /// The stream description of a `dfLa` box, completed by the decoder from the fields of the sample entry.
    static func streamDescription(
        dfLa box: BlockBufferReader,
        sampleEntryDescription: AudioStreamBasicDescription
    ) -> AudioStreamBasicDescription? {
        var description = sampleEntryDescription
        description.mFormatID = kAudioFormatFLAC
        return try? AudioFormatProperties.formatInfo(description: description, magicCookie: magicCookie(dfLa: box))
    }
}
