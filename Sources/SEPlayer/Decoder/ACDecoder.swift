//
//  ACDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.01.2025.
//

import AVFoundation

final class ACDecoder: SEDecoder {
    var isReadyForMoreMediaData: Bool {
        get {
            decoderQueue.sync { !_isDecodingSample && decompressedSamplesQueue.bufferCount <= .highWaterMark }
        }
    }

    private var converter: AVAudioConverter
    private let sampleStream: SampleStream
    private let decoderQueue: Queue
    private let returnQueue: Queue
    private let formatDescription: AVAudioFormat
    private let complessedSampleQueue: TypedCMBufferQueue<CMSampleBuffer>
    private let decompressedSamplesQueue: TypedCMBufferQueue<CMSampleBuffer>

    private var _isDecodingSample: Bool = false
    private var _samplesInDecode: Int = 0
    private var _totalVideoFrames: Int = 0

    private var _totalDroppedVideoFrames: Int = 0
    private var _corruptedVideoFrames = 0
    private var _lastDecodingError: Error?

    private var isInvalidated = false
    private var didProducedSample: (() -> Void)?

    init(
        formatDescription: CMVideoFormatDescription,
        sampleStream: SampleStream,
        decoderQueue: Queue,
        returnQueue: Queue,
        decompressedSamplesQueue: TypedCMBufferQueue<CMSampleBuffer>
    ) throws {
        self.formatDescription = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        self.sampleStream = sampleStream
        self.decoderQueue = decoderQueue
        self.returnQueue = returnQueue
        self.complessedSampleQueue = try TypedCMBufferQueue<CMSampleBuffer>(
            capacity: .maximumCapacity,
            handlers: .unsortedSampleBuffers
        )
        self.decompressedSamplesQueue = decompressedSamplesQueue

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: AVAudioFormat(cmAudioFormatDescription: formatDescription), to: outFormat) else {
            throw DecoderErrors.cannotCreateConverter
        }
        self.converter = converter
    }

    func readSamples(enqueueDecodedSample: Bool, didProducedSample: @escaping () -> Void, completion: @escaping (Error?) -> Void) {
        guard isReadyForMoreMediaData else {
            self.didProducedSample = nil
            completion(DecoderErrors.decoderQueueIsFull); return
        }

        do {
            switch try sampleStream.readData(to: complessedSampleQueue) {
            case .didReadBuffer:
                guard let buffer = complessedSampleQueue.dequeue() else { fallthrough }
                self.didProducedSample = didProducedSample
                enqueueSample(sampleBuffer: buffer) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        returnQueue.async { completion(error) }
                        return
                    }

                    returnQueue.async {
                        didProducedSample()
                        self.readSamples(enqueueDecodedSample: enqueueDecodedSample, didProducedSample: didProducedSample, completion: completion)
                    }
                }
            case .nothingRead:
                completion(DecoderErrors.nothingToRead)
            }
        } catch {
            completion(error)
        }
    }

    func flush() {
        decoderQueue.sync {
            try? decompressedSamplesQueue.reset()
            converter.reset()
        }
    }

    func invalidate() {
        decoderQueue.sync {
            flush()
            isInvalidated = true
        }
    }
}

private extension ACDecoder {
    func enqueueSample(sampleBuffer: CMSampleBuffer, completion: @escaping (Error?) -> Void) {
        decoderQueue.async { [self] in
            decodeNextSample(sampleBuffer: sampleBuffer, completion: completion)
        }
    }

    func decodeNextSample(sampleBuffer: CMSampleBuffer, completion: @escaping (Error?) -> Void) {
        assert(decoderQueue.isCurrent())
        _isDecodingSample = true
        _samplesInDecode = sampleBuffer.numSamples
        print("AUDIO New sample!!!, pts = \(sampleBuffer.presentationTimeStamp.seconds)")

        var offset = 0
        for i in 0..<sampleBuffer.numSamples {
            guard let buffer = makeInputBuffer(size: sampleBuffer.totalSampleSize) as? AVAudioCompressedBuffer else { continue }
            let sampleSize = sampleBuffer.sampleSize(at: i)
            let headerSize = 0
            let byteCount = sampleSize - headerSize
            buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(byteCount)
            )
            buffer.packetCount = 1
            buffer.byteLength = UInt32(byteCount)

            if let blockBuffer = sampleBuffer.dataBuffer {
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: offset + headerSize,
                    dataLength: byteCount,
                    destination: buffer.data
                )

                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4410) else {
                    fatalError()
                    continue
                }

                var error: NSError?
                convert(with: converter, from: buffer, to: outBuffer, error: &error)
                if let error {
                    print(error)
                }

                let decodedSample = try! makeSampleBuffer(
                    from: outBuffer,
                    presentationTimeStamp: sampleBuffer.sampleTimingInfo(at: i).presentationTimeStamp
                )
                try! decompressedSamplesQueue.enqueue(decodedSample)
                returnQueue.async { self.didProducedSample?() }
                offset += sampleSize
            }
        }
        _isDecodingSample = false
        _samplesInDecode = 0
        completion(nil)
    }

    private func makeInputBuffer(size: Int) -> AVAudioBuffer? {
        return AVAudioCompressedBuffer(format: formatDescription, packetCapacity: 2, maximumPacketSize: 1024)
    }

    private func convert(
        with converter: AVAudioConverter,
        from sourceBuffer: AVAudioCompressedBuffer,
        to destinationBuffer: AVAudioPCMBuffer,
        error outError: NSErrorPointer
    ) {
        // input each buffer only once
        var newBufferAvailable = true

        let inputBlock : AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if newBufferAvailable {
                outStatus.pointee = .haveData
                newBufferAvailable = false
                return sourceBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        converter.convert(to: destinationBuffer, error: outError, withInputFrom: inputBlock)
    }
}

private extension ACDecoder {
    enum DecoderErrors: Error {
        case cannotCreateConverter
        case decoderQueueIsFull
        case nothingToRead
    }
}

private extension ACDecoder {
    private func makeSampleBuffer(from audioListBuffer: AVAudioPCMBuffer, presentationTimeStamp sampleTime: CMTime) throws -> CMSampleBuffer {
        let blockBuffer = try makeBlockBuffer(from: audioListBuffer)
        var sampleBuffer: CMSampleBuffer? = nil

        do {
            return try CMSampleBuffer(
                dataBuffer: blockBuffer,
                formatDescription: audioListBuffer.format.formatDescription,
                numSamples: CMItemCount(audioListBuffer.frameLength),
                presentationTimeStamp: sampleTime,
                packetDescriptions: []
            )
        } catch {
            throw error
        }
    }

    private func makeBlockBuffer(from audioListBuffer: AVAudioPCMBuffer) throws -> CMBlockBuffer {
        var status: OSStatus
        var outBlockListBuffer: CMBlockBuffer? = nil

        status = CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: 0, flags: 0, blockBufferOut: &outBlockListBuffer)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard let blockListBuffer = outBlockListBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: -1)
        }

        for audioBuffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioListBuffer.audioBufferList)) {
            
            var outBlockBuffer: CMBlockBuffer? = nil
            let dataByteSize = Int(audioBuffer.mDataByteSize)
            
            status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataByteSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataByteSize,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &outBlockBuffer)
            
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            guard let blockBuffer = outBlockBuffer else {
                throw NSError(domain: NSOSStatusErrorDomain, code: -1)
            }

            status = CMBlockBufferReplaceDataBytes(
                with: audioBuffer.mData!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataByteSize)
            
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }

            status = CMBlockBufferAppendBufferReference(
                blockListBuffer,
                targetBBuf: blockBuffer,
                offsetToData: 0,
                dataLength: CMBlockBufferGetDataLength(blockBuffer),
                flags: 0)

            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }

        return blockListBuffer
    }
}

private extension CMItemCount {
    static let maximumCapacity = 240
    static let highWaterMark = 120
    static let lowWaterMark = 15
    static let maxDecodingFrames = 10
}
