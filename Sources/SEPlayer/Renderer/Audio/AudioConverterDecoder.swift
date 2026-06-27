//
//  AudioConverterDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 03.01.2026.
//

import AVFoundation
import Decoder
import SEPlayerCommon

final class AudioConverterDecoder: SimpleDecoder<ACDecoderInputBuffer, ACDecoderOutputBuffer, ACDecoderError>, AVFDecoder {
    private let audioConverter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let outputFormatDescription: CMAudioFormatDescription
    private let decompressedBuffer: AVAudioPCMBuffer
    private let maximumPacketSize: Int
    private let memoryPool: CMMemoryPool
    private let outputNumberOfBytes: UInt32
    private let fakeAudioBufferList: UnsafeMutableAudioBufferListPointer

    init(
        decodeQueue: Queue = Queues.sharedAudioDecodeQueue,
        format: Format,
        highWaterMark: Int = 240,
    ) throws {
        inputFormat = try AVAudioFormat(cmAudioFormatDescription: format.buildFormatDescription())
        let outputFormat = if let channelLayout = inputFormat.channelLayout {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                interleaved: true,
                channelLayout: channelLayout
            )
        } else {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: true
            )
        }
        guard let outputFormat else { throw ACDecoderError.formatNotSupported }
        self.outputFormat = outputFormat
        outputFormatDescription = outputFormat.formatDescription

        fakeAudioBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        outputNumberOfBytes = 4096 * outputFormatDescription.audioStreamBasicDescription!.mBytesPerPacket

        guard let audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ACDecoderError.formatNotSupported
        }

        self.audioConverter = audioConverter
        guard let decompressedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
            throw ACDecoderError.failedToCreateAudioBuffer
        }
        self.decompressedBuffer = decompressedBuffer

        maximumPacketSize = format.maxInputSize > 0 ? format.maxInputSize : .defaultInputBufferSize
        memoryPool = CMMemoryPoolCreate(options: nil)

        let handlers: CMBufferQueue.Handlers = .init { handlers in
            handlers.compare { lhs, rhs in
                guard let lhs = lhs as? ACDecoderOutputBuffer,
                      let rhs = rhs as? ACDecoderOutputBuffer else {
                    return .compareEqualTo
                }

                if lhs.sampleFlags.contains(.endOfStream) {
                    return .compareGreaterThan
                }
                if rhs.sampleFlags.contains(.endOfStream) {
                    return .compareLessThan
                }

                guard let lhsSampleBuffer = lhs.sampleBuffer,
                   let rhsSampleBuffer = rhs.sampleBuffer else {
                    return .compareEqualTo
                }

                if lhsSampleBuffer.presentationTimeStamp == rhsSampleBuffer.presentationTimeStamp {
                    return .compareEqualTo
                } else if lhsSampleBuffer.presentationTimeStamp > rhsSampleBuffer.presentationTimeStamp {
                    return .compareGreaterThan
                } else {
                    return .compareLessThan
                }
            }

            handlers.getPresentationTimeStamp { buffer in
                (buffer as? ACDecoderOutputBuffer)?.sampleBuffer?.presentationTimeStamp ?? .invalid
            }

            handlers.getDuration { buffer in
                (buffer as? ACDecoderOutputBuffer)?.sampleBuffer?.duration ?? .invalid
            }
        }
        try super.init(
            decodeQueue: decodeQueue,
            inputBuffersCount: highWaterMark,
            outputBuffersCount: highWaterMark,
            handlers: handlers
        )
        try setInitialInputBufferSize(maximumPacketSize)
    }

    deinit {
        fakeAudioBufferList.unsafeMutablePointer.deallocate()
    }

    static func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support.FormatSupport {
        let formatDescription = try format.buildFormatDescription()
        guard formatDescription.mediaType == .audio else { return .unsupportedType }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let outputFormat = if let channelLayout = inputFormat.channelLayout {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                interleaved: true,
                channelLayout: channelLayout
            )
        } else {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: true
            )
        }

        guard let outputFormat else { return .unsupportedSubtype }
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        return converter != nil ? .handled : .unsupportedSubtype
    }

    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool {
        return false
    }

    override func createInputBuffer() -> ACDecoderInputBuffer {
        ACDecoderInputBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: maximumPacketSize)
    }

    override func createOutputBuffer() -> ACDecoderOutputBuffer {
        ACDecoderOutputBuffer { [unowned self] buffer in
            releaseOutputBuffer(buffer as! ACDecoderOutputBuffer)
        }
    }

    override func createDecodeError(_ error: any Error) -> ACDecoderError {
        guard let error = error as? ACDecoderError else {
            return .unknown(error)
        }

        return error
    }

    override func decode(
        inputBuffer: ACDecoderInputBuffer,
        outputBuffer: ACDecoderOutputBuffer,
        reset: Bool,
        isolation: isolated PlayerActor = #isolation
    ) async throws(ACDecoderError) {
        do {
            if reset { audioConverter.reset() }

            var needToProvideData = true

//            struct UncheckedSendable<T>: @unchecked Sendable { let value: T }
//            let boxed = UncheckedSendable(value: inputBuffer)  audioConverter.convert will synchronously execute closure'

//            let outputBlockBuffer = try! CMBlockBuffer(
//                length: Int(outputNumberOfBytes),
//                allocator: CMMemoryPoolGetAllocator(memoryPool),
//                flags: [.assureMemoryNow]
//            )
//
//            let frameLength = try! outputBlockBuffer.withUnsafeMutableBytes { bufferPointer in
//                fakeAudioBufferList[0].mData = bufferPointer.baseAddress
//                fakeAudioBufferList[0].mDataByteSize = UInt32(bufferPointer.count)
//                fakeAudioBufferList[0].mNumberChannels = outputFormat.channelCount
//
//                let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, bufferListNoCopy: fakeAudioBufferList.unsafePointer)!
//                audioConverter.convert(to: outputBuffer, error: &error) { packetCount, status in
//                    guard needToProvideData else {
//                        status.pointee = .noDataNow
//                        return nil
//                    }
//
//                    if boxed.value.flags.contains(.endOfStream) {
//                        status.pointee = .endOfStream
//                        return nil
//                    }
//
//                    needToProvideData = false
//                    status.pointee = .haveData
//                    return boxed.value.audioBuffer
//                }
//
//                return outputBuffer.frameLength
//            }
            let block: AVAudioConverterInputBlock = { packetCount, status in
                guard needToProvideData else {
                    status.pointee = .noDataNow
                    return nil
                }

                if inputBuffer.flags.contains(.endOfStream) {
                    status.pointee = .endOfStream
                    return nil
                }

                needToProvideData = false
                status.pointee = .haveData
                return inputBuffer.audioBuffer
            }

            try withoutActuallyEscaping(block) { escapingClosure in
                var error: NSError?
                audioConverter.convert(to: decompressedBuffer, error: &error, withInputFrom: escapingClosure)
                if let error { throw error }
            }

//            guard frameLength > 0 else {
//                outputBuffer.shouldBeSkipped = true
//                return
//            }

            guard decompressedBuffer.frameLength > 0 else {
                outputBuffer.shouldBeSkipped = true
                return
            }

            let sampleBuffer = try! CMSampleBuffer(
                dataBuffer: nil,
                dataReady: false,
                formatDescription: outputFormatDescription,
                numSamples: CMItemCount(decompressedBuffer.frameLength),
                presentationTimeStamp: inputBuffer.time.presentationTimeStamp,
                packetDescriptions: [],
                makeDataReadyHandler: { _ in return noErr }
            )
//            var sampleBuffer: CMSampleBuffer!
//            let result = try! CMAudioSampleBufferCreateReadyWithPacketDescriptions(
//                allocator: nil,
//                dataBuffer: outputBlockBuffer,
//                formatDescription: outputFormatDescription,
//                sampleCount: CMItemCount(frameLength),
//                presentationTimeStamp: inputBuffer.time.presentationTimeStamp,
//                packetDescriptions: nil,
//                sampleBufferOut: &sampleBuffer
//            )
            try sampleBuffer.setDataBuffer(
                fromAudioBufferList: decompressedBuffer.audioBufferList,
                blockBufferMemoryAllocator: CMMemoryPoolGetAllocator(memoryPool),
                flags: []
            )

            outputBuffer.initBuffer(time: inputBuffer.time, sampleBuffer: sampleBuffer)
        } catch {
            SELogger.error(.renderer, "ACDecoder unexpected error = \(error)")

            if let error = error as? ACDecoderError {
                throw error
            } else {
                throw .unknown(error)
            }
        }
    }
}

enum ACDecoderError: Error {
    case unknown(Error)
    case formatNotSupported
    case failedToCreateAudioBuffer
    case missingData
}

final class ACDecoderInputBuffer: DecoderInputBuffer {
    var audioBuffer: AVAudioCompressedBuffer

    init(
        format: AVAudioFormat,
        packetCapacity: Int = 1,
        maximumPacketSize: Int = 0,
        bufferReplacementMode: DecoderInputBuffer.BufferReplacementMode = .enabled,
        paddingSize: Int = 0
    ) {
        let maximumPacketSize = if format.streamDescription.pointee.mBytesPerPacket > 0 {
            max(Int(format.streamDescription.pointee.mBytesPerPacket), maximumPacketSize)
        } else if maximumPacketSize > 0 {
            maximumPacketSize
        } else {
            Int.defaultInputBufferSize
        }

        audioBuffer = AVAudioCompressedBuffer(
            format: format,
            packetCapacity: AVAudioPacketCount(packetCapacity),
            maximumPacketSize: maximumPacketSize
        )

        super.init(bufferReplacementMode: bufferReplacementMode, paddingSize: paddingSize)
    }

    override func commitWrite(amount: Int) {
        audioBuffer.byteLength = UInt32(amount)
        audioBuffer.packetCount = 1
        audioBuffer.packetDescriptions?.pointee = .init(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: audioBuffer.byteLength
        )
    }

    override func getData() throws -> UnsafeMutableRawBufferPointer? {
        UnsafeMutableRawBufferPointer(
            start: audioBuffer.data,
            count: audioBuffer.maximumPacketSize
        )
    }

    override func clear() {
        super.clear()
        audioBuffer.byteLength = 0
        audioBuffer.packetCount = 0
        audioBuffer.packetDescriptions?.pointee = .init()
    }

    override func createReplacementBuffer(requiredCapacity: Int) throws {
        guard bufferReplacementMode == .enabled else {
            throw BufferErrors.allocationFailed
        }

        audioBuffer = AVAudioCompressedBuffer(
            format: audioBuffer.format,
            packetCapacity: audioBuffer.packetCapacity,
            maximumPacketSize: requiredCapacity
        )
    }
}

final class ACDecoderOutputBuffer: SimpleDecoderOutputBuffer {
    var sampleBuffer: CMSampleBuffer?

    func initBuffer(time: CMSampleTimingInfo, sampleBuffer: CMSampleBuffer) {
        super.initBuffer(time: time, size: .zero)
//        self.timeUs = timeUs
        self.sampleBuffer = sampleBuffer
    }

    override func release() {
        sampleBuffer = nil
        super.release()
    }
}

private extension Int {
    static let defaultInputBufferSize: Int = 10 * 1024
}

private func inputDataProc(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    outDataPacketDescription?.pointee = .allocate(capacity: Int(ioNumberDataPackets.pointee))

    let blockBuffer = try! CMBlockBuffer().makeContiguous()
    let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
    bufferList[0].mData = try! blockBuffer.withUnsafeMutableBytes { $0.baseAddress }
    bufferList[0].mDataByteSize = UInt32(blockBuffer.dataLength)

    return noErr
}
