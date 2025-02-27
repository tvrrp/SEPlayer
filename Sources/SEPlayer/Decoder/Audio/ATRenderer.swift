//
//  ATRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AudioToolbox
import AVFoundation

final class ATRenderer: BaseSERenderer {
    private var format: AudioStreamBasicDescription
    private var destinationFormat: AudioStreamBasicDescription
    private var converter: AudioConverterRef?
    
    private let audioSync: AudioSync2
    private let bufferSize: UInt32
    private let outputBufferList: UnsafeMutableAudioBufferListPointer
    private let outputPointer: UnsafeMutableRawPointer
    private let outputQueue: TypedCMBufferQueue<CMSampleBuffer>

    private var _pendingSamples = [CMSampleBuffer]()
    private var _isDecodingSample = false
    private var _samplesBeingDecoded = 0

    private let memoryPool: CMMemoryPool

    init(
        format: CMAudioFormatDescription,
        clock: CMClock,
        queue: Queue,
        sampleStream: SampleStream
    ) throws {
        self.format = format.audioStreamBasicDescription!
        let outputSampleRate = AVAudioSession.sharedInstance().sampleRate
        destinationFormat = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * self.format.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * self.format.mChannelsPerFrame,
            mChannelsPerFrame: self.format.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        outputQueue = try .init(capacity: .highWaterMark)
        audioSync = try AudioSync2(queue: queue, outputQueue: outputQueue, outputFormat: destinationFormat, outputSampleRate: outputSampleRate)
        outputBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        bufferSize = destinationFormat.mBytesPerPacket * destinationFormat.mChannelsPerFrame * 1024
        outputPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(bufferSize),
            alignment: MemoryLayout<UInt8>.alignment
        )
        outputBufferList.unsafeMutablePointer.pointee.mBuffers.mNumberChannels = destinationFormat.mChannelsPerFrame
        outputBufferList.unsafeMutablePointer.pointee.mBuffers.mDataByteSize = bufferSize
        outputBufferList.unsafeMutablePointer.pointee.mBuffers.mData = outputPointer

        memoryPool = CMMemoryPoolCreate(options: nil)

        try super.init(clock: clock, queue: queue, sampleStream: sampleStream)
        try createAudioConverter()
    }

    override func isReady() -> Bool {
        return super.isReady() && audioSync.hasPendingData()
    }

    override func getMediaClock() -> MediaClock? {
        return self
    }

    override func start() {
        super.start()
        try! audioSync.start(with: clock.microseconds)
    }

    override func setPlaybackRate(new playbackRate: Float) throws {
        try super.setPlaybackRate(new: playbackRate)
        try audioSync.setPlaybackRate(new: playbackRate)
    }

    override func queueInputSample(sampleBuffer: CMSampleBuffer) -> Bool {
        assert(queue.isCurrent())
        guard _samplesBeingDecoded < .highWaterMark else { return false }
        _pendingSamples.append(sampleBuffer)
        _samplesBeingDecoded += 1
        decodeNextSampleIfNeeded()
        return true
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
        guard !outputQueue.isFull else { return false }
//        let sampleBuffer = try! CMSampleBuffer(
//            copying: sample,
//            withNewTiming: sample.sampleTimingInfos().map { oldTiming in
//                CMSampleTimingInfo(
//                    duration: oldTiming.duration,
//                    presentationTimeStamp: .from(microseconds: presenationTime),
//                    decodeTimeStamp: .zero
//                )
//            }
//        )

//        if isStarted || audioSync.hasPendingData() {
//            try! outputQueue.enqueue(sampleBuffer)
//        } else {
//            audioSync.enqueueImmediately(sample)
//        }
       
        return audioSync.enqueueImmediately(sample)
    }
}

extension ATRenderer: MediaClock {
    func getPosition() -> Int64 {
        return audioSync.getPosition()
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

    private func decodeNextSampleIfNeeded() {
        guard !_isDecodingSample, !_pendingSamples.isEmpty else { return }
        _isDecodingSample = true
        let sample = _pendingSamples.removeFirst()

        // async as AudioConverterFillComplexBuffer is sync
        queue.async {
            self.decodeSample(sample)
        }
    }

    private func decodeSample(_ sampleBuffer: CMSampleBuffer) {
        guard let converter else { return }

        var ioOutputDataPackets: UInt32 = bufferSize

        do {
            let result = try sampleBuffer.withUnsafeAudioStreamPacketDescriptions { description in
                var description = description[0]
                return try sampleBuffer.withAudioBufferList { audioBuffer, _ in
                    var dataObject = DataObject(
                        bufferList: audioBuffer.unsafeMutablePointer,
                        packetDescription: &description
                    )

                    let result = withUnsafeMutablePointer(to: &dataObject) { dataObjectRef in
                        AudioConverterFillComplexBuffer(
                            converter, // inAudioConverter
                            converterComplexBufferCallback, // inInputDataProc
                            dataObjectRef, // inInputDataProcUserData
                            &ioOutputDataPackets, // ioOutputDataPacketSize
                            outputBufferList.unsafeMutablePointer, // outOutputData
                            nil // outPacketDescription
                        )
                    }

                    return result
                }
            }

            if result != noErr && result != ConverterErrors.custom_noMoreData.rawValue {
                throw DecoderErrors.osStatus(.init(rawValue: result), result)
            }
        } catch {
            print(error)
        }

        enqueueSample(
            from: outputBufferList.unsafeMutablePointer,
            compressedSample: sampleBuffer
        )
    }

    private func enqueueSample(from audioBufferList: UnsafeMutablePointer<AudioBufferList>, compressedSample: CMSampleBuffer) {
        do {
            let itemsCount = audioBufferList.pointee.mBuffers.mDataByteSize
            let formatDescription = try CMFormatDescription(audioStreamBasicDescription: destinationFormat)
            let blockBuffer = try makeBlockBuffer(from: audioBufferList)

            let sampleBuffer = try CMSampleBuffer(
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                numSamples: Int(itemsCount),
                presentationTimeStamp: compressedSample.presentationTimeStamp,
                packetDescriptions: []
            )

            try decompressedSamplesQueue.enqueue(sampleBuffer)
        } catch {
            print(error)
        }
        _samplesBeingDecoded -= 1
        _isDecodingSample = false
        decodeNextSampleIfNeeded()
    }

    private func makeBlockBuffer(from audioListBuffer: UnsafeMutablePointer<AudioBufferList>) throws -> CMBlockBuffer {
        let dataByteSize = Int(audioListBuffer.pointee.mBuffers.mDataByteSize)
        let outBlockListBuffer = try CMBlockBuffer()

        for audioBuffer in UnsafeMutableAudioBufferListPointer(audioListBuffer) {
            let dataByteSize = Int(audioBuffer.mDataByteSize)
            let allocator = CMMemoryPoolGetAllocator(memoryPool)

            var blockBuffer: CMBlockBuffer!
            try CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: nil,
                blockLength: dataByteSize,
                blockAllocator: allocator,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataByteSize,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            ).validate()

            let outBlockBuffer = try CMBlockBuffer(length: dataByteSize, allocator: CMMemoryPoolGetAllocator(memoryPool), flags: .assureMemoryNow)
            let pointer = UnsafeRawBufferPointer(start: audioBuffer.mData!, count: dataByteSize)
            try outBlockBuffer.replaceDataBytes(with: pointer)
            try outBlockListBuffer.append(bufferReference: outBlockBuffer)
        }

        return outBlockListBuffer
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
    let bufferList: UnsafeMutablePointer<AudioBufferList>
    let packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>
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
        dataPacketsCount.pointee = 0
        ioData.pointee.mBuffers.mDataByteSize = 0
        return ConverterErrors.custom_noMoreData.rawValue
    }

    outDataPacketDescription?.pointee = dataObject.pointee.packetDescription
    ioData.pointee = dataObject.pointee.bufferList.pointee

    dataObject.pointee.didReadData = true
    dataPacketsCount.pointee = 1
    return noErr
}

private extension CMItemCount {
    static let highWaterMark = 30
}
