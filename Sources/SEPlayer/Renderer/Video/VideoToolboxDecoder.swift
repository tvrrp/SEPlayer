//
//  VideoToolboxDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

import VideoToolbox

final class VideoToolboxDecoder: SEDecoder {
    private let queue: Queue
    private var formatDescription: CMFormatDescription
    private let decompressedSamplesQueue: TypedCMBufferQueue<VideoOutputWrapper>
    private var decompressionSession: VTDecompressionSession?

    private var playbackSpeed: Float = 1.0

    private let individualBufferSize: Int
    private let compressedBufferPool: CompressedBufferPool<UnsafeMutableRawBufferPointer, VideoOutputWrapper>

    private var _pendingSamples = [(Int, CMSampleBuffer, SampleFlags)]()
    private var _decodingSamples = NSHashTable<Cancellable>()
    private var _isDecodingSample = false
    private var _framedBeingDecoded = 0

    init(queue: Queue, format: Format) throws {
        self.queue = queue
        self.formatDescription = try format.buildFormatDescription()
        decompressedSamplesQueue = try TypedCMBufferQueue<VideoOutputWrapper>(capacity: .highWaterMark) { rhs, lhs in
            guard rhs != lhs else { return .compareEqualTo }

            return rhs > lhs ? .compareGreaterThan : .compareLessThan
        }
        let individualBufferSize = format.maxInputSize > 0 ? format.maxInputSize : Int.defaultInputBufferSize
        self.individualBufferSize = individualBufferSize

        compressedBufferPool = .init(
            capacity: .highWaterMark,
            decodedQueue: decompressedSamplesQueue,
            allocateBuffer: {
                let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: individualBufferSize)
                return UnsafeMutableRawBufferPointer(buffer)
            },
            deallocateBuffer: { buffer in
                buffer.deallocate()
            }
        )

        try createDecompressionSession()
    }

    func dequeueInputBufferIndex() -> Int? {
        assert(queue.isCurrent())
        return compressedBufferPool.tryAcquireIndex()
    }

    func dequeueInputBuffer(for index: Int) -> UnsafeMutableRawBufferPointer {
        assert(queue.isCurrent())
        return compressedBufferPool.bufferView(for: index)
    }

    func queueInputBuffer(for index: Int, inputBuffer: DecoderInputBuffer) throws {
        assert(queue.isCurrent())
        let buffer = try inputBuffer.dequeue()

        let isEndOfStream = inputBuffer.flags.contains(.endOfStream)
        let blockBuffer: CMBlockBuffer? = if !isEndOfStream {
            try CMBlockBuffer(buffer: buffer[0..<inputBuffer.size], deallocator: { _, _ in })
        } else {
            nil
        }

        let sampleTimings = !isEndOfStream ? [inputBuffer.sampleTimings] : []
        let sampleSizes = !isEndOfStream ? [inputBuffer.size] : []

        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            numSamples: 1,
            sampleTimings: sampleTimings,
            sampleSizes: sampleSizes
        )

        _pendingSamples.append((index, sampleBuffer, inputBuffer.flags))
        decodeNextSampleIfNeeded()
    }

    func dequeueOutputBuffer() -> VideoOutputWrapper? {
        assert(queue.isCurrent())
        return compressedBufferPool.dequeueDecoded()
    }

    func flush() throws {
        assert(queue.isCurrent())
        _decodingSamples.allObjects.forEach { $0.cancel() }
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
        }
        _isDecodingSample = false
        _framedBeingDecoded = 0
        _pendingSamples.removeAll()
        try compressedBufferPool.flush()
    }

    func release() {
        assert(queue.isCurrent())
        try? flush()

        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }
        try? compressedBufferPool.release()
    }

    private func createDecompressionSession() throws {
        var imageBufferAttributes: [NSString: Any] = [:]
        #if targetEnvironment(simulator)
        imageBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey as NSString] = [
            kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: true
        ]
        #endif

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &decompressionSession
        )

        if status != noErr {
            throw VTDSessionErrors.osStatus(.init(rawValue: status))
        }
    }

    private func decodeNextSampleIfNeeded() {
        guard !_isDecodingSample, !_pendingSamples.isEmpty else { return }

        _isDecodingSample = true
        let pending = _pendingSamples.removeFirst()
        let cancellable = decodeSample(index: pending.0, sampleBuffer: pending.1, sampleFlags: pending.2)
        _decodingSamples.add(cancellable)
    }

    private func decodeSample(index: Int, sampleBuffer: CMSampleBuffer, sampleFlags: SampleFlags) -> Cancellable? {
        assert(queue.isCurrent())
        let cancellable = Cancellable(queue: queue)
        if sampleFlags.contains(.endOfStream) {
            handleSample(response: .init(
                status: noErr,
                infoFlags: .init(),
                imageBuffer: nil,
                presentationTimeStamp: .zero,
                sampleIndex: index,
                sampleFlags: sampleFlags,
                cancellable: cancellable
            ))
            return nil
        }

        guard let decompressionSession else { return nil }

        var decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        if playbackSpeed <= 1.0 { decodeFlags.insert(._1xRealTimePlayback) }
        var infoFlagsOut: VTDecodeInfoFlags = []

        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            infoFlagsOut: &infoFlagsOut
        ) { [weak self] status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            guard let self else { return }

            queue.async {
                self.handleSample(
                    response: .init(
                        status: status,
                        infoFlags: infoFlags,
                        imageBuffer: imageBuffer,
                        presentationTimeStamp: presentationTimeStamp,
                        sampleIndex: index,
                        sampleFlags: sampleFlags,
                        cancellable: cancellable
                    )
                )
            }
        }

        if status != noErr {
            let error = VTDSessionErrors.osStatus(.init(rawValue: status))

            if case let .osStatus(vTError) = error, vTError == .invalidSession {
                _isDecodingSample = false
                self._pendingSamples.insert((index, sampleBuffer, sampleFlags), at: 0)
                try! createDecompressionSession() // TODO: fixme
            }
        }

        return cancellable
    }

    private func handleSample(response: VTDecoderResponce) {
        defer {
            _decodingSamples.remove(response.cancellable)
            _isDecodingSample = false
            _framedBeingDecoded -= 1
            decodeNextSampleIfNeeded()
        }

        do {
            guard !response.cancellable.isCancelled else { return }

            guard response.status == noErr else {
                throw VTDSessionErrors.osStatus(.init(rawValue: response.status))
            }

            try compressedBufferPool.onDecodeSuccess(
                fromCompressedIndex: response.sampleIndex,
                decoded: VideoOutputWrapper(
                    imageBuffer: response.imageBuffer,
                    sampleFlags: response.sampleFlags,
                    presentationTime: response.presentationTimeStamp.microseconds
                )
            )
        } catch {
            compressedBufferPool.onDecodeError(fromCompressedIndex: response.sampleIndex)
            print(error)
        }
    }
}

extension VideoToolboxDecoder: CARendererDecoder {
    static func getCapabilities() -> RendererCapabilities {
        VideoToolboxCapabilitiesResolver()
    }

    func setPlaybackSpeed(_ speed: Float) {
        self.playbackSpeed = speed
    }

    // TODO: decoder reuse with flush for allocating larger buffers if needed
    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool {
        assert(queue.isCurrent())
        guard let decompressionSession,
              let newFormatDescription = try? newFormat.buildFormatDescription() else {
            return false
        }

        if let oldFormat, oldFormat.maxInputSize > 0, newFormat.maxInputSize > 0,
           oldFormat.maxInputSize < newFormat.maxInputSize {
            return false
        } else if newFormat.maxInputSize > individualBufferSize {
            return false
        }

        let result = VTDecompressionSessionCanAcceptFormatDescription(
            decompressionSession,
            formatDescription: newFormatDescription
        )
        if result { formatDescription = newFormatDescription }
        return result
    }
}

extension VideoToolboxDecoder {
    private struct VTDecoderResponce {
        let status: OSStatus
        let infoFlags: VTDecodeInfoFlags
        let imageBuffer: CVImageBuffer?
        let presentationTimeStamp: CMTime
        let sampleIndex: Int
        let sampleFlags: SampleFlags
        let cancellable: Cancellable
    }

    enum VTDSessionErrors: Error {
        case osStatus(VTError?)

        enum VTError: OSStatus {
            case propertyNotSupported = -12900
            case propertyReadOnly = -12901
            case wrongParameter = -12902
            case invalidSession = -12903
            case allocationFailed = -12904
            case pixelTransferNotSupported_1 = -12905
            case pixelTransferNotSupported_2 = -8961
            case couldNotFindVideoDecoder = -12906
            case couldNotCreateInstance = -12907
            case couldNotFindVideoEncoder = -12908
            case videoDecoderBadData_1 = -12909
            case videoDecoderBadData_2 = -8969
            case videoDecoderUnsupportedDataFormat_1 = -12910
            case videoDecoderUnsupportedDataFormat_2 = -8970
            case videoDecoderMalfunction_1 = -12911
            case videoDecoderMalfunction_2 = -8960
            case videoEncoderMalfunction = -12912
            case videoDecoderNotAvailableNow = -12913
            case pixelRotationNotSupported = -12914
            case videoEncoderNotAvailableNow = -12915
            case formatDescriptionChangeNotSupported = -12916
            case insufficientSourceColorData = -12917
            case couldNotCreateColorCorrectionData = -12918
            case colorSyncTransformConvertFailed = -12919
            case videoDecoderAuthorization = -12210
            case videoEncoderAuthorization = -12211
            case colorCorrectionPixelTransferFailed = -12212
            case multiPassStorageIdentifierMismatch = -12213
            case multiPassStorageInvalid = -12214
            case frameSiloInvalidTimeStamp = -12215
            case frameSiloInvalidTimeRange = -12216
            case couldNotFindTemporalFilter = -12217
            case pixelTransferNotPermitted = -12218
            case colorCorrectionImageRotationFailed = -12219
            case videoDecoderRemoved = -17690
            case sessionMalfunction = -17691
            case videoDecoderNeedsRosetta = -17692
            case videoEncoderNeedsRosetta = -17693
            case videoDecoderReferenceMissing = -17694
            case videoDecoderCallbackMessaging = -17695
            case videoDecoderUnknown = -17696
            case extensionDisabled = -17697
            case videoEncoderMVHEVCVideoLayerIDsMismatch = -17698
            case couldNotOutputTaggedBufferGroup = -17699
            case couldNotFindExtension = -19510
            case extensionConflict = -19511
        }
    }
}

final class VideoOutputWrapper: CoreVideoBuffer, Comparable {
    let imageBuffer: CVImageBuffer?
    let sampleFlags: SampleFlags
    let presentationTime: Int64

    init(imageBuffer: CVImageBuffer?, sampleFlags: SampleFlags, presentationTime: Int64) {
        self.imageBuffer = imageBuffer
        self.sampleFlags = sampleFlags
        self.presentationTime = presentationTime
    }

    static func < (lhs: VideoOutputWrapper, rhs: VideoOutputWrapper) -> Bool {
        lhs.presentationTime < rhs.presentationTime
    }

    static func == (lhs: VideoOutputWrapper, rhs: VideoOutputWrapper) -> Bool {
        lhs.presentationTime == rhs.presentationTime
    }
}

private struct VideoToolboxCapabilitiesResolver: RendererCapabilities {
    let trackType: TrackType = .video

    func supportsFormat(_ format: Format) -> Bool {
        guard let mimeType = format.sampleMimeType else { return false }

        switch mimeType {
        case .videoH264, .videoH265:
            return true
        default:
            return false
        }
    }
}

private final class Cancellable {
    var isCancelled: Bool { queue.sync { _isCancelled } }

    private let queue: Queue
    private var _isCancelled = false

    init(queue: Queue) {
        self.queue = queue
    }

    func cancel() { queue.sync { _isCancelled = true } }
}

private extension Int {
    static let highWaterMark = 10
    static let defaultInputBufferSize: Int = 768 * 1024
}
