//
//  AudioConverterDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.04.2025.
//

import AudioToolbox
import CoreMedia.CMBlockBuffer

final class AudioConverterDecoder: AQDecoder {
    private let queue: Queue
    private var sourceFormat: AudioStreamBasicDescription
    private var sourceChannelLayout: ManagedAudioChannelLayout?
    private var destinationFormat: AudioStreamBasicDescription
    private let decompressedSamplesQueue: TypedCMBufferQueue<AudioSampleWrapper>
    private var audioConverter: AudioConverterRef?

    private let outputBufferList: UnsafeMutableAudioBufferListPointer
    private let individualBufferSize: Int
    private var buffers: [UnsafeMutableRawPointer]
    private var buffersInUse: [Bool]
    private var bufferCounter = 0

    private var decodedSamples: [UnsafeMutableRawPointer]
    private var samplesInUse: [Bool]
    private var samplesCounter = 0

    private var _pendingSamples = [(Int, CMSampleBuffer, SampleFlags)]()
    private var _isDecodingSample = false
    private var _framedBeingDecoded = 0

    init(queue: Queue, formatDescription: CMFormatDescription) throws {
        guard let sourceFormat = formatDescription.audioStreamBasicDescription else { fatalError() }
        self.queue = queue
        self.sourceFormat = sourceFormat
        self.sourceChannelLayout = formatDescription.audioChannelLayout
        destinationFormat = AudioStreamBasicDescription(
            format: .pcmInt16,
            sampleRate: sourceFormat.mSampleRate,
            numOfChannels: sourceFormat.mChannelsPerFrame
        )
        decompressedSamplesQueue = try! TypedCMBufferQueue<AudioSampleWrapper>(capacity: .highWaterMark) { rhs, lhs in
            guard rhs.presentationTime != lhs.presentationTime else { return .compareEqualTo }
            
            return rhs.presentationTime > lhs.presentationTime ? .compareGreaterThan : .compareLessThan
        }
        let size = 1024 * 10
        buffers = (0..<Int.highWaterMark).map { _ in
            UnsafeMutableRawPointer.allocate(
                byteCount: size,
                alignment: MemoryLayout<UInt8>.alignment
            )
        }
        outputBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        let individualBufferSize = Int(destinationFormat.mBytesPerPacket * destinationFormat.mChannelsPerFrame * 1024)
        self.individualBufferSize = individualBufferSize
        decodedSamples = (0..<Int.highWaterMark).map { _ in
            UnsafeMutableRawPointer.allocate(
                byteCount: individualBufferSize,
                alignment: MemoryLayout<UInt8>.alignment
            )
        }
        buffersInUse = Array(repeating: false, count: .highWaterMark)
        samplesInUse = Array(repeating: false, count: .highWaterMark)

        try! createAudioConverter()
    }

    func canReuseDecoder(oldFormat: CMFormatDescription?, newFormat: CMFormatDescription) -> Bool {
        guard let oldAudioFormat = oldFormat?.audioStreamBasicDescription,
              let newAudioFormat = newFormat.audioStreamBasicDescription else {
            return false
        }

        return oldAudioFormat == newAudioFormat
    }

    static func getCapabilities() -> RendererCapabilities {
        AudioConverterRendererCapabilities()
    }

    func dequeueInputBufferIndex() -> Int? {
        assert(queue.isCurrent())

        guard !buffersInUse[bufferCounter], !samplesInUse[samplesCounter] else {
            return nil
        }

        let index = bufferCounter
        buffersInUse[bufferCounter] = true
        samplesInUse[samplesCounter] = true

        bufferCounter += 1
        if bufferCounter >= .highWaterMark {
            bufferCounter = 0
        }

        samplesCounter += 1
        if samplesCounter >= .highWaterMark {
            samplesCounter = 0
        }

        return index
    }

    func dequeueInputBuffer(for index: Int) -> UnsafeMutableRawPointer {
        assert(queue.isCurrent())
        return buffers[index]
    }

    func queueInputBuffer(for index: Int, inputBuffer: DecoderInputBuffer) throws {
        assert(queue.isCurrent())
        let buffer = try! inputBuffer.dequeue()

        let isEndOfStream = inputBuffer.flags.contains(.endOfStream)
        let blockBuffer: CMBlockBuffer? = if !isEndOfStream {
            try! CMBlockBuffer(
                length: inputBuffer.size,
                allocator: { _ in
                    return buffer
                },
                deallocator: { _, _ in },
                flags: .assureMemoryNow
            )
        } else {
            nil
        }

        let formatDescription = try! CMFormatDescription(audioStreamBasicDescription: sourceFormat)
        let sampleTimings = !isEndOfStream ? [inputBuffer.sampleTimings] : []
        let sampleSizes = !isEndOfStream ? [inputBuffer.size] : []

        let sampleBuffer = try! CMSampleBuffer(
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            numSamples: 1,
            sampleTimings: sampleTimings,
            sampleSizes: sampleSizes
        )
        _pendingSamples.append((index, sampleBuffer, inputBuffer.flags))
        decodeNextSampleIfNeeded()
    }

    func dequeueOutputBuffer() -> AudioSampleWrapper? {
        assert(queue.isCurrent())
        return decompressedSamplesQueue.dequeue()
    }

    func flush() throws {
        assert(queue.isCurrent())
        if let audioConverter {
            AudioConverterReset(audioConverter)
        }
        try! decompressedSamplesQueue.reset()
        _isDecodingSample = false
        _framedBeingDecoded = 0
        _pendingSamples.removeAll()
        bufferCounter = 0
        buffersInUse = buffersInUse.map { _ in false }
        samplesCounter = 0
        samplesInUse = samplesInUse.map { _ in false }
    }

    func release() {
        assert(queue.isCurrent())
        if let audioConverter {
            AudioConverterDispose(audioConverter)
            self.audioConverter = nil
        }
        free(outputBufferList.unsafeMutablePointer)
        _isDecodingSample = false
        _framedBeingDecoded = 0
        _pendingSamples.removeAll()
        buffers.forEach { $0.deallocate() }
        decodedSamples.forEach { $0.deallocate() }
    }

    private func createAudioConverter() throws {
        assert(queue.isCurrent())
        let status = AudioConverterNew(&sourceFormat, &destinationFormat, &audioConverter)

        if status != noErr {
            throw AudioConverterErrors.osStatus(.init(rawValue: status))
        }
    }

    private func decodeNextSampleIfNeeded() {
        guard !_isDecodingSample, !_pendingSamples.isEmpty else { return }

        _isDecodingSample = true
        let (index, sample, flags) = _pendingSamples.removeFirst()
//        queue.async {
            self.decodeSample(index: index, sampleBuffer: sample, sampleFlags: flags)
//        }
    }

    private func decodeSample(index: Int, sampleBuffer: CMSampleBuffer, sampleFlags: SampleFlags) {
        assert(queue.isCurrent())

        if sampleFlags.contains(.endOfStream) {
            handleSample(index: index, itemsCount: .zero, pts: .zero, sampleFlags: sampleFlags)
            return
        }
        guard let audioConverter else { return }

        var ioOutputDataPackets: UInt32 = UInt32(individualBufferSize)
        var packetDescription = AudioStreamPacketDescription()

        outputBufferList[0].mNumberChannels = destinationFormat.mChannelsPerFrame
        outputBufferList[0].mDataByteSize = UInt32(individualBufferSize)
        outputBufferList[0].mData = decodedSamples[index]
        let pointer = outputBufferList.unsafeMutablePointer

        do {
            let result = try! sampleBuffer.withUnsafeAudioStreamPacketDescriptions { description in
                try! sampleBuffer.withAudioBufferList { audioBuffer, _ in
                    let descriptionPointer = UnsafeMutablePointer<AudioStreamPacketDescription>
                        .allocate(capacity: 1)
                    descriptionPointer.initialize(to: description[0])

                    var dataObject = DataObject(
                        bufferList: audioBuffer,
                        packetDescription: descriptionPointer
                    )

                    let result = withUnsafeMutablePointer(to: &dataObject) { dataObjectRef in
                        AudioConverterFillComplexBuffer(
                            audioConverter,
                            converterComplexBufferCallback,
                            dataObjectRef,
                            &ioOutputDataPackets,
                            pointer,
                            &packetDescription
                        )
                    }
                    descriptionPointer.deallocate()
                    return result
                }
            }

            if result != noErr && result != AudioConverterErrors.Status.custom_noMoreData.rawValue {
                throw AudioConverterErrors.osStatus(.init(rawValue: result))
            }

            handleSample(
                index: index,
                itemsCount: Int(outputBufferList[0].mDataByteSize),
                pts: sampleBuffer.presentationTimeStamp,
                sampleFlags: sampleFlags
            )

            _framedBeingDecoded -= 1
            _isDecodingSample = false
            decodeNextSampleIfNeeded()
        } catch {
            handleSample(
                index: index,
                itemsCount: .zero,
                pts: .zero,
                sampleFlags: sampleFlags
            )
        }

        buffersInUse[index] = false
    }

    var converterComplexBufferCallback: @convention(c) (
        _ converter: AudioConverterRef,
        _ dataPacketsCount: UnsafeMutablePointer<UInt32>,
        _ ioData: UnsafeMutablePointer<AudioBufferList>,
        _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
        _ userData: UnsafeMutableRawPointer?
    ) -> OSStatus = { converter, dataPacketsCount, ioData, outDataPktDesc, userData in
        guard let dataObject = userData?.assumingMemoryBound(to: DataObject.self) else {
            return AudioConverterErrors.Status.custom_nilDataObjectPointer.rawValue
        }

        let ioDataPointer = UnsafeMutableAudioBufferListPointer(ioData)
        guard !dataObject.pointee.didReadData else {
            dataPacketsCount.pointee = 0
            ioDataPointer[0].mDataByteSize = 0
            return AudioConverterErrors.Status.custom_noMoreData.rawValue
        }

        outDataPktDesc?.pointee = dataObject.pointee.packetDescription
        ioDataPointer[0].mData = dataObject.pointee.bufferList[0].mData
        ioDataPointer[0].mDataByteSize = dataObject.pointee.bufferList[0].mDataByteSize
        ioDataPointer[0].mNumberChannels = dataObject.pointee.bufferList[0].mNumberChannels

        dataObject.pointee.didReadData = true
        dataPacketsCount.pointee = 1
        return noErr
    }

    func handleSample(index: Int, itemsCount: Int, pts: CMTime, sampleFlags: SampleFlags) {
        do {
            let formatDescription = try! CMFormatDescription(
                audioStreamBasicDescription: destinationFormat,
                layout: sourceChannelLayout
            )
            let sampleBuffer: CMSampleBuffer

            if itemsCount > 0 {
                let buffer = decodedSamples[index]
                let blockBuffer = try! CMBlockBuffer(
                    length: itemsCount,
                    allocator: { _ in
                        return buffer
                    },
                    deallocator: { [weak self] _, _ in
                        guard let self else { return }
                        queue.async { self.samplesInUse[index] = false }
                    },
                    flags: .assureMemoryNow
                )
                sampleBuffer = try! CMSampleBuffer(
                    dataBuffer: blockBuffer,
                    formatDescription: formatDescription,
                    numSamples: itemsCount,
                    presentationTimeStamp: pts,
                    packetDescriptions: []
                )
            } else if sampleFlags.contains(.endOfStream) {
                samplesInUse[index] = false
                sampleBuffer = try  CMSampleBuffer(
                    dataBuffer: nil,
                    formatDescription: formatDescription,
                    numSamples: itemsCount,
                    sampleTimings: [],
                    sampleSizes: []
                )
            } else {
                fatalError()
                samplesInUse[index] = false
                return
            }

            try! decompressedSamplesQueue.enqueue(.init(
                sampleFlags: sampleFlags,
                presentationTime: pts.microseconds,
                audioBuffer: sampleBuffer
            ))
        } catch {
            samplesInUse[index] = false
            // TODO: need to do smth
            fatalError()
        }
    }
}

extension AudioConverterDecoder {
    private struct DataObject {
        let bufferList: UnsafeMutableAudioBufferListPointer//UnsafeMutablePointer<AudioBufferList>
        let packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>
        var didReadData: Bool = false
        var error: Error?
    }
}

struct AudioConverterRendererCapabilities: RendererCapabilities {
    let trackType: TrackType = .audio

    func supportsFormat(_ format: CMFormatDescription) -> Bool {
        guard format.mediaType == .audio, var sourceFormat = format.audioStreamBasicDescription else {
            return false
        }
        var destinationFormat = AudioStreamBasicDescription(
            format: .pcmInt16,
            sampleRate: sourceFormat.mSampleRate,
            numOfChannels: sourceFormat.mChannelsPerFrame
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&sourceFormat, &destinationFormat, &converter)

        if status == noErr, let converter {
            AudioConverterDispose(converter)
            return true
        } else {
            return false
        }
    }
}

final class AudioSampleWrapper: AQOutputBuffer {
    let sampleFlags: SampleFlags
    let presentationTime: Int64
    let audioBuffer: CMSampleBuffer?

    init(
        sampleFlags: SampleFlags,
        presentationTime: Int64,
        audioBuffer: CMSampleBuffer? = nil
    ) {
        self.sampleFlags = sampleFlags
        self.presentationTime = presentationTime
        self.audioBuffer = audioBuffer
    }
}

private extension Int {
    static let highWaterMark = 30
    static let defaultInputBufferSize: Int = 768 * 1024
}
