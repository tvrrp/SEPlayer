//
//  ATRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AudioToolbox
import AVFoundation

final class ATRenderer: BaseSERenderer {
    let format: CMAudioFormatDescription
    var converter: AudioConverterRef?
    
    init(
        format: CMAudioFormatDescription,
        clock: CMClock,
        queue: Queue,
        sampleStream: SampleStream
    ) throws {
        self.format = format
        try super.init(clock: clock, queue: queue, sampleStream: sampleStream)
        try createAudioConverter()
    }
    
    override func isReady() -> Bool {
        true
    }
    
    override func queueInputSample(sampleBuffer: CMSampleBuffer, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    override func processOutputSample(
        position: Int64,
        elapsedRealtime: Int64,
        outputStreamStartPosition: Int64,
        presenationTime: Int64,
        sample: CMSampleBuffer,
        isDecodeOnlySample: Bool,
        isLastOutputSample: Bool
    ) -> Bool {
        return false
    }
}

extension ATRenderer {
    func createAudioConverter() throws {
        var sourceFormat = format.audioStreamBasicDescription!
        let sampleRate = AVAudioSession.sharedInstance().sampleRate
        let numberOfChannels = AVAudioSession.sharedInstance().outputNumberOfChannels
        var destinationFormat = AudioStreamBasicDescription(
            mSampleRate: AVAudioSession.sharedInstance().sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let status = AudioConverterNew(
            &sourceFormat,
            &destinationFormat,
            &converter
        )

        if status != noErr {
            let error = DecoderErrors.osStatus(.init(rawValue: status), status)
            throw error
        }
    }
}

extension ATRenderer {
    enum DecoderErrors: Error {
        case osStatus(AudioToolboxErrors?, OSStatus)

        enum AudioToolboxErrors: Int32 {
            case formatNotSupported = 1718449215
            case operationNotSupported = 1869627199
            case propertyNotSupported = 1886547824
            case invalidInputSize = 1768846202
            case invalidOutputSize = 1869902714
            case unspecifiedError = 2003329396
            case badPropertySizeError = 561211770
            case requiresPacketDescriptionsError = 561015652
            case inputSampleRateOutOfRange = 560558962
            case outputSampleRateOutOfRange = 560952178
            case hardwareInUse = 1752656245
            case noHardwarePermission = 1885696621
        }
    }
}
