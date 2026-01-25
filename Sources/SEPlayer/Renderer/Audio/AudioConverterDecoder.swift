//
//  AudioConverterDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 03.01.2026.
//

import AVFoundation

final class AudioConverterDecoder: SimpleDecoder<ACDecoderInputBuffer, ACDecoderOutputBuffer, ACDecoderError> {
    private let audioConverter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let decompressedBuffer: AVAudioPCMBuffer
    private let maximumPacketSize: Int
    private let memoryPool: CMMemoryPool

    init(
        decodeQueue: Queue = Queues.sharedDecodeQueue,
        format: Format,
        highWaterMark: Int = 60,
    ) throws {
        inputFormat = try AVAudioFormat(cmAudioFormatDescription: format.buildFormatDescription())
        let outputFormat = if let channelLayout = inputFormat.channelLayout {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                interleaved: inputFormat.isInterleaved,
                channelLayout: channelLayout
            )
        } else {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: inputFormat.isInterleaved
            )
        }
        guard let outputFormat else { throw ACDecoderError.formatNotSupported }
        self.outputFormat = outputFormat

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
        super.init(decodeQueue: decodeQueue, inputBuffersCount: highWaterMark, outputBuffersCount: highWaterMark)
        try setInitialInputBufferSize(maximumPacketSize)
    }

    static func formatSupported(_ formatDescription: CMFormatDescription) -> Bool {
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let outputFormat = if let channelLayout = inputFormat.channelLayout {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                interleaved: inputFormat.isInterleaved,
                channelLayout: channelLayout
            )
        } else {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: inputFormat.isInterleaved
            )
        }

        guard let outputFormat else { return false }
        return AVAudioConverter(from: inputFormat, to: outputFormat) != nil
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
            var error: NSError?
            var needToProvideData = true

            struct UncheckedSendable<T>: @unchecked Sendable { let value: T }
            let boxed = UncheckedSendable(value: inputBuffer) // audioConverter.convert will synchronously execute closure
            audioConverter.convert(to: decompressedBuffer, error: &error) { _, status in
                guard needToProvideData else {
                    status.pointee = .noDataNow
                    return nil
                }

                if boxed.value.flags.contains(.endOfStream) {
                    status.pointee = .endOfStream
                    return nil
                }

                needToProvideData = false
                status.pointee = .haveData
                return boxed.value.audioBuffer
            }

            if let error { throw error }

            guard decompressedBuffer.frameLength > 0 else {
                outputBuffer.shouldBeSkipped = true
                return
            }

            let sampleBuffer = try CMSampleBuffer(
                dataBuffer: nil,
                dataReady: false,
                formatDescription: outputFormat.formatDescription,
                numSamples: CMItemCount(decompressedBuffer.frameLength),
                presentationTimeStamp: .from(microseconds: inputBuffer.timeUs),
                packetDescriptions: [],
                makeDataReadyHandler: { _ in return noErr }
            )

            try sampleBuffer.setDataBuffer(
                fromAudioBufferList: decompressedBuffer.audioBufferList,
                blockBufferMemoryAllocator: CMMemoryPoolGetAllocator(memoryPool),
                flags: []
            )

            outputBuffer.initBuffer(timeUs: inputBuffer.timeUs, sampleBuffer: sampleBuffer)
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

    func initBuffer(timeUs: Int64, sampleBuffer: CMSampleBuffer) {
        self.timeUs = timeUs
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
