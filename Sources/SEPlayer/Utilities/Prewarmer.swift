//
//  Prewarmer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 09.07.2025.
//

import AVFoundation
import Extractor
import SEPlayerCommon
import VideoToolbox

/// Loads, once per process and in the background, what the first playback would otherwise wait for: the format
/// services' codecs, the audio renderer's audio queue, the hardware video decoder and the answers about playable
/// formats. Each is a one-time cost of the process, from a few milliseconds to tens on a device.
final class Prewarmer: Sendable {
    static let shared = Prewarmer()

    private static let once: Void = {
        let queue = DispatchQueue.global(qos: .utility)
        queue.async { AudioFormatServices.prewarm() }
        queue.async { prewarmAudioRenderer() }
        queue.async { prewarmVideoDecoder() }
        queue.async { _ = AVURLAsset.isPlayableExtendedMIMEType(#"video/mp4; codecs="avc1.640028,mp4a.40.2""#) }
    }()

    func prewarm() {
        _ = Self.once
    }

    /// An audio renderer creates its audio queue with the first buffer it gets, loading the audio server's connection
    /// and its spatial audio settings on the way. Without a synchronizer it never plays.
    private static func prewarmAudioRenderer() {
        let renderer = AVSampleBufferAudioRenderer()
        if let buffer = silence() {
            renderer.enqueue(buffer)
        }
        renderer.flush()
    }

    /// A few milliseconds of silent stereo linear PCM.
    private static func silence() -> CMSampleBuffer? {
        let description = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let frameCount = 256
        guard let format = try? CMAudioFormatDescription(audioStreamBasicDescription: description),
              let data = try? CMBlockBuffer(length: frameCount * Int(description.mBytesPerFrame), flags: .assureMemoryNow),
              (try? data.fillDataBytes(with: 0)) != nil else {
            return nil
        }
        return try? CMSampleBuffer(
            dataBuffer: data,
            formatDescription: format,
            numSamples: frameCount,
            presentationTimeStamp: .zero,
            packetDescriptions: []
        )
    }

    /// Creating a decompression session loads the hardware decoder.
    private static func prewarmVideoDecoder() {
        if #available(iOS 26.2, tvOS 26.2, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        }
        let sequenceParameterSet: [UInt8] = [
            0x67, 0x64, 0x00, 0x28, 0xAC, 0xD1, 0x00, 0x44, 0x03, 0xC7, 0x97, 0xC0, 0x5A, 0x80, 0x80, 0x80,
            0xA0, 0x00, 0x00, 0x7D, 0x20, 0x00, 0x17, 0x70, 0x01, 0xE3, 0x06, 0x22, 0x40,
        ]
        let pictureParameterSet: [UInt8] = [0x68, 0xEB, 0x8F, 0x2C]
        guard let format = try? CMFormatDescription(
            h264ParameterSets: [Data(sequenceParameterSet), Data(pictureParameterSet)],
            nalUnitHeaderLength: 4
        ) else {
            return
        }

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if status == noErr, let session {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
