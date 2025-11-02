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
    private let destinationFormatDescription: CMFormatDescription
    private let decompressedSamplesQueue: TypedCMBufferQueue<AudioSampleWrapper>
    private var audioConverter: AudioConverterRef?

    private var decoderCircularBuffer: DecoderCircularBuffer<BufferWrapper>
    private var lastOutputBuffer: Int = .zero

    init(queue: Queue, format: Format) throws {
        let formatDescription = try format.buildFormatDescription()
        guard let sourceFormat = formatDescription.audioStreamBasicDescription else { fatalError() }
        self.queue = queue
        self.sourceFormat = sourceFormat
        self.sourceChannelLayout = formatDescription.audioChannelLayout
        destinationFormat = AudioStreamBasicDescription(
            format: .pcmFloat32,
            sampleRate: sourceFormat.mSampleRate,
            numOfChannels: sourceFormat.mChannelsPerFrame
        )
        let sourceChannelLayout: ManagedAudioChannelLayout? = if let audioLayout = formatDescription.audioChannelLayout {
            ManagedAudioChannelLayout(tag: audioLayout.tag)
        } else {
            nil
        }

        destinationFormatDescription = try CMAudioFormatDescription(
            audioStreamBasicDescription: destinationFormat,
            layout: nil//sourceChannelLayout
        )
        decompressedSamplesQueue = try TypedCMBufferQueue<AudioSampleWrapper>(capacity: .highWaterMark) { rhs, lhs in
            guard rhs.presentationTime != lhs.presentationTime else { return .compareEqualTo }

            return rhs.presentationTime > lhs.presentationTime ? .compareGreaterThan : .compareLessThan
        }

        var size = if format.maxInputSize > 0 {
            format.maxInputSize
        } else {
            Int(sourceFormat.mFramesPerPacket * sourceFormat.mChannelsPerFrame * 10)
        }
        size = size > 0 ? size : .defaultInputBufferSize

        let individualBufferSize = Int(destinationFormat.mBytesPerPacket * destinationFormat.mChannelsPerFrame * 1024) * 10

        decoderCircularBuffer = .init(
            capacity: .highWaterMark,
            inputBufferSize: size,
            outputBufferSize: individualBufferSize,
            allocateBuffer: { bufferSize in
                let bufferList = AudioBufferList.allocate(maximumBuffers: 1)
                let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
                bufferList[0].mData = UnsafeMutableRawPointer(buffer.baseAddress)
                return .init(size: individualBufferSize, bufferList: bufferList)
            },
            deallocateBuffer: {
                $0.bufferList.deallocateAllBuffers()
            }
        )

        try createAudioConverter()
    }

    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool {
        guard let oldAudioFormat = try? oldFormat?.buildFormatDescription().audioStreamBasicDescription,
              let newAudioFormat = try? newFormat.buildFormatDescription().audioStreamBasicDescription else {
            return false
        }

        return oldAudioFormat == newAudioFormat
    }

    static func getCapabilities() -> RendererCapabilities {
        AudioConverterRendererCapabilities()
    }

    func dequeueInputBufferIndex() -> Int? {
        assert(queue.isCurrent())
        guard decoderCircularBuffer.isInputBufferAvailable, decoderCircularBuffer.isOutputBufferAvailable,
              let inputIndex = decoderCircularBuffer.dequeueInputBufferIndex(),
              let outputIndex = decoderCircularBuffer.dequeueOutputBufferIndex() else {
            return nil
        }
        lastOutputBuffer = outputIndex

        return inputIndex
    }

    func dequeueInputBuffer(for index: Int) -> UnsafeMutableRawBufferPointer {
        assert(queue.isCurrent())
        let inputBuffer = decoderCircularBuffer.getInputBuffer(index: index)
        return UnsafeMutableRawBufferPointer(start: inputBuffer.bufferList[0].mData, count: inputBuffer.size)
    }

    func queueInputBuffer(for index: Int, inputBuffer: DecoderInputBuffer) throws {
        assert(queue.isCurrent())
        decodeSample(index: index, outputIndex: lastOutputBuffer, inputBuffer: inputBuffer)
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
        try decompressedSamplesQueue.reset()
        decoderCircularBuffer.flush()
        lastOutputBuffer = 0
    }

    func release() {
        assert(queue.isCurrent())
        if let audioConverter {
            AudioConverterDispose(audioConverter)
            self.audioConverter = nil
        }

        decoderCircularBuffer.release()
    }

    private func createAudioConverter() throws {
        assert(queue.isCurrent())
        let status = AudioConverterNew(&sourceFormat, &destinationFormat, &audioConverter)

        if status != noErr {
            throw AudioConverterErrors.osStatus(.init(rawValue: status))
        }
    }

    private func decodeSample(index: Int, outputIndex: Int, inputBuffer: DecoderInputBuffer) {
        assert(queue.isCurrent())

        if inputBuffer.flags.contains(.endOfStream) {
            handleSample(index: index, outputIndex: outputIndex, itemsCount: .zero, size: .zero, pts: .zero, sampleFlags: inputBuffer.flags)
            return
        }
        guard let audioConverter else { return }

        let outputBuffer = decoderCircularBuffer.getOutputBuffer(index: outputIndex)
        let outputBufferList = outputBuffer.bufferList
        outputBufferList[0].mNumberChannels = destinationFormat.mChannelsPerFrame
        outputBufferList[0].mDataByteSize = UInt32(outputBuffer.size)
        var ioOutputDataPackets: UInt32 = UInt32(outputBuffer.size)

        do {
            let inputAudioBufferList = decoderCircularBuffer.getInputBuffer(index: index).bufferList
            inputAudioBufferList[0].mDataByteSize = UInt32(inputBuffer.size)
            inputAudioBufferList[0].mNumberChannels = sourceFormat.mChannelsPerFrame

            let packetDescriptionRef = UnsafeMutableBufferPointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            packetDescriptionRef[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(inputBuffer.size)
            )
            defer { packetDescriptionRef.deallocate() }

            var dataObject = DataObject(bufferList: inputAudioBufferList, packetDescription: packetDescriptionRef)

            let result = withUnsafeMutablePointer(to: &dataObject) { dataObjectRef in
                AudioConverterFillComplexBuffer(
                    audioConverter,
                    converterComplexBufferCallback,
                    dataObjectRef,
                    &ioOutputDataPackets,
                    outputBufferList.unsafeMutablePointer,
                    nil
                )
            }

            if result != noErr && result != AudioConverterErrors.Status.custom_noMoreData.rawValue {
                throw AudioConverterErrors.osStatus(.init(rawValue: result))
            }

            handleSample(
                index: index,
                outputIndex: outputIndex,
                itemsCount: Int(ioOutputDataPackets),
                size: Int(outputBufferList[0].mDataByteSize),
                pts: CMTime.from(microseconds: inputBuffer.time),
                sampleFlags: inputBuffer.flags
            )
        } catch {
            handleSample(
                index: index,
                outputIndex: outputIndex,
                itemsCount: .zero,
                size: .zero,
                pts: .zero,
                sampleFlags: inputBuffer.flags
            )
        }

        decoderCircularBuffer.onInputBufferAvailable(index: index)
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

        outDataPktDesc?.pointee = dataObject.pointee.packetDescription.baseAddress
        ioDataPointer[0].mData = dataObject.pointee.bufferList[0].mData
        ioDataPointer[0].mDataByteSize = dataObject.pointee.bufferList[0].mDataByteSize
        ioDataPointer[0].mNumberChannels = dataObject.pointee.bufferList[0].mNumberChannels

        dataObject.pointee.didReadData = true
        dataPacketsCount.pointee = 1
        return noErr
    }

    func handleSample(index: Int, outputIndex: Int, itemsCount: Int, size: Int, pts: CMTime, sampleFlags: SampleFlags) {
        do {
            let sampleBuffer: CMSampleBuffer
            let bufferList = decoderCircularBuffer.getOutputBuffer(index: outputIndex).bufferList

            if itemsCount > 0 {
                let blockBuffer = try CMBlockBuffer(
                    buffer: .init(start: bufferList[0].mData, count: size),
                    deallocator: { [weak self] (_, _) in
                        self?.queue.async {
                            self?.decoderCircularBuffer.onOutputBufferAvailable(index: outputIndex)
                        }
                    }
                )

                sampleBuffer = try CMSampleBuffer(
                    dataBuffer: blockBuffer,
                    formatDescription: destinationFormatDescription,
                    numSamples: CMItemCount(itemsCount),
                    presentationTimeStamp: .zero,
                    packetDescriptions: []
                )
            } else if sampleFlags.contains(.endOfStream) {
                decoderCircularBuffer.onOutputBufferAvailable(index: outputIndex)
                sampleBuffer = try CMSampleBuffer(
                    dataBuffer: nil,
                    formatDescription: destinationFormatDescription,
                    numSamples: itemsCount,
                    sampleTimings: [],
                    sampleSizes: []
                )
            } else {
                decoderCircularBuffer.onOutputBufferAvailable(index: outputIndex)
                return
            }

            try decompressedSamplesQueue.enqueue(.init(
                sampleFlags: sampleFlags,
                presentationTime: pts.microseconds,
                audioBuffer: sampleBuffer,
                outputBufferIndex: outputIndex
            ))
        } catch {
            decoderCircularBuffer.onOutputBufferAvailable(index: outputIndex)
        }
    }
}

extension AudioConverterDecoder {
    private struct DataObject {
        let bufferList: UnsafeMutableAudioBufferListPointer
        let packetDescription: UnsafeMutableBufferPointer<AudioStreamPacketDescription>
        var didReadData: Bool = false
        var error: Error?
    }
}

struct AudioConverterRendererCapabilities: RendererCapabilities {
    let trackType: TrackType = .audio

    func supportsFormat(_ format: Format) -> Bool {
        guard let formatDescription = try? format.buildFormatDescription(),
              formatDescription.mediaType == .audio,
              var description = formatDescription.audioStreamBasicDescription else {
            return false
        }

        var destinationFormat = AudioStreamBasicDescription(
            format: .pcmInt16,
            sampleRate: description.mSampleRate,
            numOfChannels: description.mChannelsPerFrame
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&description, &destinationFormat, &converter)

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
    let outputBufferIndex: Int

    init(
        sampleFlags: SampleFlags,
        presentationTime: Int64,
        audioBuffer: CMSampleBuffer? = nil,
        outputBufferIndex: Int
    ) {
        self.sampleFlags = sampleFlags
        self.presentationTime = presentationTime
        self.audioBuffer = audioBuffer
        self.outputBufferIndex = outputBufferIndex
    }
}

private struct BufferWrapper {
    let size: Int
    let bufferList: UnsafeMutableAudioBufferListPointer
}

private extension Int {
    static let highWaterMark = 60
    static let defaultInputBufferSize: Int = 10 * 1024
}
