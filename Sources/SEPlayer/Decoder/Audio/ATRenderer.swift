//
//  ATRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AudioToolbox
import AVFoundation

final class ATRenderer: BaseSERenderer {
    var format: AudioStreamBasicDescription
    var destinationFormat: AudioStreamBasicDescription
    var converter: AudioConverterRef?

    init(
        format: CMAudioFormatDescription,
        clock: CMClock,
        queue: Queue,
        sampleStream: SampleStream
    ) throws {
        self.format = format.audioStreamBasicDescription!
        destinationFormat = AudioStreamBasicDescription(
            mSampleRate: AVAudioSession.sharedInstance().sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * self.format.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * self.format.mChannelsPerFrame,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try super.init(clock: clock, queue: queue, sampleStream: sampleStream)
        try createAudioConverter()
    }

    override func isReady() -> Bool {
        true
    }

    override func queueInputSample(sampleBuffer: CMSampleBuffer, completion: @escaping (Bool) -> Void) {
        guard let converter else { completion(false); return }

        var dataObject = DataObject(sample: sampleBuffer)
        let bufferSize: UInt32 = destinationFormat.mBytesPerPacket * destinationFormat.mChannelsPerFrame * 1024
        let outputPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(bufferSize),
            alignment: MemoryLayout<UInt8>.alignment
        )
        let outputBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        var outBufferRef = outputBufferList.unsafeMutablePointer.pointee
        outBufferRef.mBuffers.mNumberChannels = destinationFormat.mChannelsPerFrame
        outBufferRef.mBuffers.mDataByteSize = bufferSize
        outBufferRef.mBuffers.mData = outputPointer
        var ioOutputDataPackets: UInt32 = bufferSize

        let result = withUnsafeMutablePointer(to: &dataObject) { dataObjectRef in
            AudioConverterFillComplexBuffer(
                converter, // inAudioConverter
                converterComplexBufferCallback, // inInputDataProc
                dataObjectRef, // inInputDataProcUserData
                &ioOutputDataPackets, // ioOutputDataPacketSize
                &outBufferRef, // outOutputData
                nil // outPacketDescription
            )
        }

        let sampleBuffer = try! CMSampleBuffer(
            dataBuffer: nil,
            formatDescription: nil,
            numSamples: 1,
            sampleTimings: sampleBuffer.sampleTimingInfos(),
            sampleSizes: []
        )
        try! decompressedSamplesQueue.enqueue(sampleBuffer)

        outputBufferList.unsafeMutablePointer.deallocate()
        outputPointer.deallocate()
        if result != noErr && result != ConverterErrors.custom_noMoreData.rawValue {
            completion(false)
        }

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
        return true
    }
}

extension ATRenderer {
    func createAudioConverter() throws {
        let status = AudioConverterNew(
            &format,
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

        enum AudioToolboxErrors: OSStatus {
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

            case custom_nilDataObjectPointer = -1001
            case custom_sampleBufferAudioBufferEmpty = -1002
            case custom_noMoreData = -1003
            case custom_unknown = -1004
        }
    }
}

private struct DataObject {
    let sample: CMSampleBuffer
    var didReadData: Bool = false
    var error: Error?
}

private typealias ConverterErrors = ATRenderer.DecoderErrors.AudioToolboxErrors

private func converterComplexBufferCallback(
    _ converter: AudioConverterRef,
    dataPacketsCount: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let dataObject = userData?.assumingMemoryBound(to: DataObject.self) else {
        return ConverterErrors.custom_nilDataObjectPointer.rawValue
    }

    guard !dataObject.pointee.didReadData else {
        ioData.pointee.mBuffers.mDataByteSize = 0
        return ConverterErrors.custom_noMoreData.rawValue
    }

    do {
        if let packetDescriptionRef = outDataPacketDescription?.pointee {
            try dataObject.pointee.sample.withUnsafeAudioStreamPacketDescriptions { pointer in
                packetDescriptionRef.pointee = pointer[0]
            }
        }

        try dataObject.pointee.sample.withAudioBufferList() { pointer, blockBuffer in
            ioData.pointee = pointer.unsafeMutablePointer.pointee
        }
    } catch {
        dataObject.pointee.error = error
        return ConverterErrors.custom_sampleBufferAudioBufferEmpty.rawValue
    }

    dataObject.pointee.didReadData = true
    dataPacketsCount.pointee = 1
    return noErr
}
