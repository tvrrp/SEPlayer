//
//  AudioConverterDecoder2.swift
//  SEPlayer
//
//  Created by tvrrp on 03.05.2026.
//

import AudioToolbox
import CoreMedia
import SEPlayerCommon

final class AudioConverterDecoder2 {
    let outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    private let decodeQueue: Queue
    private let inputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    private let maxOutputSampleDuration: CMTime
    private var audioConverter: AudioConverterRef?
    private var inputFormat: CMFormatDescription
    private var inputFormatBasicDescription: AudioStreamBasicDescription
    private var doesInputUsesPacketDescriptions: Bool
    private var outputFormat: CMFormatDescription
    private var outputFormatBasicDescription: AudioStreamBasicDescription
    private var outputBufferSize: Int
    private let outputAudioBufferList: UnsafeMutableAudioBufferListPointer
    private let memoryPool: CMMemoryPool
    private let lock: UnfairLock

    private var packetDescriptions: UnsafeMutableBufferPointer<AudioStreamPacketDescription>
    private var currentSampleBuffer: CMSampleBuffer?
    private var referenceBlockBuffer: CMBlockBuffer?
    private var offsetInCurrentSampleBuffer: Int?
    private var currentSamplePts: CMTime = .invalid
    private var previousError: Error?

    init(
        inputFormat: Format,
        decodeQueue: Queue = Queues.sharedAudioDecodeQueue,
        inputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>,
        outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>? = nil,
        maxOutputSampleDuration: CMTime = .init(value: 1, timescale: 2) // 500ms
    ) throws {
        self.decodeQueue = decodeQueue
        self.inputBufferQueue = inputBufferQueue
        self.outputBufferQueue = try outputBufferQueue ?? .init()
        self.inputFormat = try inputFormat.buildFormatDescription()
        self.maxOutputSampleDuration = maxOutputSampleDuration

        guard var inputBasicDescription = self.inputFormat.audioStreamBasicDescription else {
            throw ACDecoderError.formatNotSupported
        }

        inputFormatBasicDescription = inputBasicDescription
        doesInputUsesPacketDescriptions = inputBasicDescription.mBytesPerPacket == 0 || inputBasicDescription.mFramesPerPacket == 0
        var outputBasicDescription = AudioStreamBasicDescription(
            format: .pcmFloat32,
            sampleRate: inputBasicDescription.mSampleRate,
            numOfChannels: inputBasicDescription.mChannelsPerFrame,
            isInterleaved: true
        )
        outputFormatBasicDescription = outputBasicDescription

        outputFormat = try CMAudioFormatDescription(
            audioStreamBasicDescription: outputBasicDescription,
            layout: self.inputFormat.audioChannelLayout
        )

        try AudioConverterNew(
            &inputBasicDescription,
            &outputBasicDescription,
            &audioConverter
        )
        .validate()

        outputAudioBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        memoryPool = CMMemoryPoolCreate(options: nil)
        lock = UnfairLock()

        let frameCount = CMTimeConvertScale(
            maxOutputSampleDuration,
            timescale: Int32(outputBasicDescription.mSampleRate),
            method: .roundTowardPositiveInfinity
        ).value

        outputBufferSize = Int(outputBasicDescription.mBytesPerFrame) * Int(frameCount)
        packetDescriptions = .allocate(capacity: 0)
    }

    deinit {
        outputAudioBufferList.unsafeMutablePointer.deallocate()
        packetDescriptions.deallocate()
    }

    static func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support.FormatSupport {
        guard var inputFormat = try format.buildFormatDescription().audioStreamBasicDescription else {
            return .unsupportedType
        }

        var outputFormat = AudioStreamBasicDescription(
            format: .pcmFloat32,
            sampleRate: inputFormat.mSampleRate,
            numOfChannels: inputFormat.mChannelsPerFrame
        )

        var audioConverter: AudioConverterRef?
        let result = AudioConverterNew(&inputFormat, &outputFormat, &audioConverter)
        if let audioConverter { AudioConverterDispose(audioConverter) }

        return result != noErr ? .handled : .unsupportedSubtype
    }

    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool {
        guard var newInputFormat = try? newFormat.buildFormatDescription() else {
            return false
        }

        return inputFormat.equalTo(newInputFormat)
    }

    func decodeUntilHighWaterMark(_ highWaterMark: CMTime = .init(seconds: 2, preferredTimescale: 1000)) throws {
        try lock.withLock {
            if let previousError {
                self.previousError = nil
                throw previousError
            }
        }

        let triggerToken = try outputBufferQueue.installTrigger(condition: .whenDurationBecomesGreaterThanOrEqualTo(highWaterMark))
        decodeQueue.async { [self] in
            defer { try? outputBufferQueue.removeTrigger(triggerToken) }
            do {
                var isDataAvailable = true
                while isDataAvailable, !outputBufferQueue.testTrigger(triggerToken) {
                    isDataAvailable = try decodeInternal()
                }
            } catch {
                self.previousError = error
                return
            }
        }
    }

    func flush() {
        decodeQueue.async { [self] in
            if let audioConverter { AudioConverterReset(audioConverter) }
            currentSampleBuffer = nil
            referenceBlockBuffer = nil
            currentSamplePts = .invalid
            offsetInCurrentSampleBuffer = nil
            try? outputBufferQueue.reset()
        }
    }

    private func decodeInternal() throws -> Bool {
        assert(decodeQueue.isCurrent())
        if let newFormatDescription = nextFormatDescription() {
            try updateDecoder(inputFormat: newFormatDescription)
        }

        guard let audioConverter else { throw ACDecoderError.formatNotSupported }

        let outputBlockBuffer = try CMBlockBuffer(
            length: outputBufferSize,
            allocator: CMMemoryPoolGetAllocator(memoryPool),
            flags: [.assureMemoryNow]
        )

        let (packetsProduced, isDataAvailable) = try outputBlockBuffer.withUnsafeMutableBytes { bufferPointer in
            outputAudioBufferList[0].mDataByteSize = UInt32(bufferPointer.count)
            outputAudioBufferList[0].mData = bufferPointer.baseAddress
            let packetsPerLoop = UInt32(bufferPointer.count) / outputFormatBasicDescription.mBytesPerPacket
            // On input, the size of the output buffer (in the outOutputData parameter)
            // expressed in number packets in the audio converter’s output format.
            var decodedPackets = UInt32(packetsPerLoop)

            let status = AudioConverterFillComplexBuffer(
                audioConverter,
                inputDataProc,
                Unmanaged<AudioConverterDecoder2>.passUnretained(self).toOpaque(),
                &decodedPackets,
                outputAudioBufferList.unsafeMutablePointer,
                nil // not required for decoding
            )

            if status != noErr || status != AudioConverterErrors.Status.customNoMoreData.rawValue {
                try lock.withLock {
                    if let previousError {
                        self.previousError = nil
                        throw previousError
                    } else {
                        throw AudioConverterErrors.osStatus(.init(rawValue: status))
                    }
                }
            }

            return (decodedPackets, status != AudioConverterErrors.Status.customNoMoreData.rawValue)
        }

        guard packetsProduced > 0 else {
            // We may run out of space in current blockBuffer and should continue decoding
            return isDataAvailable ? try decodeInternal() : false
        }

        let outputSampleBuffer = try CMSampleBuffer(
            dataBuffer: outputBlockBuffer,
            formatDescription: outputFormat,
            numSamples: CMItemCount(packetsProduced),
            sampleTimings: [.init(
                duration: CMTime(
                    value: CMTimeValue(packetsProduced),
                    timescale: CMTimeScale(outputFormatBasicDescription.mSampleRate)
                ),
                presentationTimeStamp: currentSamplePts,
                decodeTimeStamp: .invalid
            )],
            sampleSizes: [Int(packetsProduced * outputFormatBasicDescription.mBytesPerFrame)]
        )

        clenupPreviousSampleBufferIfNeeded()
        try outputBufferQueue.enqueue(outputSampleBuffer)
        return isDataAvailable
    }

    fileprivate func decodeLoop(
        _ inAudioConverter: AudioConverterRef,
        _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        _ ioData: UnsafeMutablePointer<AudioBufferList>,
        _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        do {
            guard let sampleBuffer = try dequeueSamples() else {
                ioNumberDataPackets.pointee = 0
                return AudioConverterErrors.Status.customNoMoreData.rawValue
            }

            currentSampleBuffer = sampleBuffer
            currentSamplePts = sampleBuffer.presentationTimeStamp

            return try sampleBuffer.withUnsafeAudioStreamPacketDescriptions { descriptions in
                let startOffset = offsetInCurrentSampleBuffer ?? .zero
                let remaining = descriptions.count - startOffset

                return try sampleBuffer.withAudioBufferList(blockBufferMemoryAllocator: CMMemoryPoolGetAllocator(memoryPool)) { bufferListPointer, blockBuffer in
                    referenceBlockBuffer = blockBuffer

                    if doesInputUsesPacketDescriptions {
                        resizePacketDescriptionsArray(remaining)
                        outDataPacketDescription?.pointee = packetDescriptions.baseAddress
                    }

                    let packetsRange = Range(uncheckedBounds: (startOffset, startOffset + remaining))
                    packetDescriptions.update(fromContentsOf: descriptions[packetsRange])
                    packetDescriptions.initialize(fromContentsOf: descriptions[packetsRange])

                    let ioData = UnsafeMutableAudioBufferListPointer(ioData)
                    ioData.unsafeMutablePointer.pointee.mNumberBuffers = 1
                    ioData[0].mNumberChannels = inputFormatBasicDescription.mChannelsPerFrame
                    ioData[0].mDataByteSize = bufferListPointer[0].mDataByteSize
                    ioData[0].mData = bufferListPointer[0].mData
                    ioNumberDataPackets.pointee = UInt32(remaining)

                    let newOffset = startOffset + remaining
                    if newOffset >= descriptions.count {
                        self.offsetInCurrentSampleBuffer = nil
                    } else {
                        self.offsetInCurrentSampleBuffer = newOffset
                    }

                    return noErr
                }
            }
        } catch {
            ioNumberDataPackets.pointee = 0
            offsetInCurrentSampleBuffer = nil
            previousError = error
            return AudioConverterErrors.Status.customError.rawValue
        }
    }

    private func dequeueSamples() throws -> CMSampleBuffer? {
        assert(decodeQueue.isCurrent())
        clenupPreviousSampleBufferIfNeeded()

        let sampleBuffer: CMSampleBuffer?
        if let currentSampleBuffer {
            sampleBuffer = currentSampleBuffer
        } else {
            guard nextFormatDescription() == nil else { return nil }
            sampleBuffer = inputBufferQueue.dequeueIfDataReady()
        }

        return (sampleBuffer?.numSamples ?? .zero) > 0 ? sampleBuffer : nil
    }

    private func clenupPreviousSampleBufferIfNeeded() {
        assert(decodeQueue.isCurrent())
        if offsetInCurrentSampleBuffer == nil {
            if let currentSampleBuffer {
                if currentSampleBuffer.attachments[.postNotificationWhenConsumed] != nil {
                    NotificationCenter.default.post(
                        name: .init(kCMSampleBufferConsumerNotification_BufferConsumed as String),
                        object: currentSampleBuffer
                    )
                }

                if let audioConverter, currentSampleBuffer.attachments[.drainAfterDecoding] != nil {
                    AudioConverterReset(audioConverter)
                }
            }

            currentSampleBuffer = nil
            referenceBlockBuffer = nil
            currentSamplePts = .invalid
        }
    }

    private func resizePacketDescriptionsArray(_ newCapacity: Int) {
        assert(decodeQueue.isCurrent())
        guard packetDescriptions.count < newCapacity else { return }
        let newBuffer = UnsafeMutableBufferPointer<AudioStreamPacketDescription>.allocate(capacity: newCapacity)
        packetDescriptions.deinitialize(); packetDescriptions.deallocate()
        packetDescriptions = newBuffer
    }

    private func nextFormatDescription() -> CMAudioFormatDescription? {
        assert(decodeQueue.isCurrent())
        guard currentSampleBuffer == nil,
              let headSampleBuffer = inputBufferQueue.head,
              headSampleBuffer.attachments[.resetDecoderBeforeDecoding] != nil,
              let newFormat = headSampleBuffer.formatDescription, !newFormat.equalTo(inputFormat) else {
            return nil
        }

        return newFormat
    }

    private func updateDecoder(inputFormat: CMAudioFormatDescription) throws {
        assert(decodeQueue.isCurrent())
        guard var inputBasicDescription = inputFormat.audioStreamBasicDescription else {
            throw ACDecoderError.formatNotSupported
        }

        self.inputFormat = inputFormat
        inputFormatBasicDescription = inputBasicDescription
        doesInputUsesPacketDescriptions = inputBasicDescription.mBytesPerPacket == 0 || inputBasicDescription.mFramesPerPacket == 0
        var outputBasicDescription = AudioStreamBasicDescription(
            format: .pcmFloat32,
            sampleRate: inputBasicDescription.mSampleRate,
            numOfChannels: inputBasicDescription.mChannelsPerFrame,
            isInterleaved: true
        )
        outputFormatBasicDescription = outputBasicDescription

        outputFormat = try CMAudioFormatDescription(
            audioStreamBasicDescription: outputBasicDescription,
            layout: inputFormat.audioChannelLayout
        )

        if let audioConverter {
            AudioConverterDispose(audioConverter)
            self.audioConverter = nil
        }

        let result = try AudioConverterNew(
            &inputBasicDescription,
            &outputBasicDescription,
            &audioConverter
        )

        if result != noErr {
            throw ACDecoderError.formatNotSupported
        }

        let frameCount = CMTimeConvertScale(
            maxOutputSampleDuration,
            timescale: Int32(outputBasicDescription.mSampleRate),
            method: .roundTowardPositiveInfinity
        ).value

        outputBufferSize = Int(outputBasicDescription.mBytesPerFrame) * Int(frameCount)
    }
}

private func inputDataProc(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    let decoder = Unmanaged<AudioConverterDecoder2>.fromOpaque(inUserData!).takeUnretainedValue() // safe as we always passing userData
    return decoder.decodeLoop(inAudioConverter, ioNumberDataPackets, ioData, outDataPacketDescription)
}
