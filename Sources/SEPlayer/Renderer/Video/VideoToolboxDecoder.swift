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
    private var buffers: [UnsafeMutableRawPointer]
    private var buffersInUse: [Bool]
    private var bufferCounter = 0

    private var framesInUse: [Bool]
    private var framesReadCounter = 0
    private var framesWriteCounter = 0

    private var _pendingSamples = [(Int, CMSampleBuffer, SampleFlags)]()
    private var _isDecodingSample = false
    private var _framedBeingDecoded = 0

    init(queue: Queue, formatDescription: CMFormatDescription) throws {
        self.queue = queue
        self.formatDescription = formatDescription
        decompressedSamplesQueue = try TypedCMBufferQueue<VideoOutputWrapper>(capacity: .highWaterMark) { rhs, lhs in
            guard rhs.presentationTime != lhs.presentationTime else { return .compareEqualTo }

            return rhs.presentationTime > lhs.presentationTime ? .compareGreaterThan : .compareLessThan
        }
        let individualBufferSize = Int.defaultInputBufferSize
        self.individualBufferSize = individualBufferSize
        buffers = (0..<Int.highWaterMark).map { _ in
            UnsafeMutableRawPointer.allocate(
                byteCount: individualBufferSize,
                alignment: MemoryLayout<UInt8>.alignment
            )
        }
        buffersInUse = Array(repeating: false, count: .highWaterMark)
        framesInUse = Array(repeating: false, count: .highWaterMark)

        try createDecompressionSession()
    }

    func dequeueInputBufferIndex() -> Int? {
        assert(queue.isCurrent())
        guard buffersInUse[bufferCounter] == false, framesInUse[framesWriteCounter] == false else {
            return nil
        }

        let index = bufferCounter
        buffersInUse[bufferCounter] = true
        bufferCounter += 1
        if bufferCounter >= .highWaterMark {
            bufferCounter = 0
        }

        framesWriteCounter += 1
        if framesWriteCounter >= .highWaterMark {
            framesWriteCounter = 0
        }

        return index
    }

    func dequeueInputBuffer(for index: Int) -> UnsafeMutableRawPointer {
        assert(queue.isCurrent())
        return buffers[index]
    }

    func queueInputBuffer(for index: Int, inputBuffer: DecoderInputBuffer) throws {
        assert(queue.isCurrent())
        let buffer = try inputBuffer.dequeue()

        let blockBuffer = try CMBlockBuffer(
            length: inputBuffer.size,
            allocator: { _ in
                return buffer
            },
            deallocator: { _, _ in },
            flags: .assureMemoryNow
        )

        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            numSamples: 1,
            sampleTimings: [inputBuffer.sampleTimings],
            sampleSizes: [inputBuffer.size]
        )
        _pendingSamples.append((index, sampleBuffer, inputBuffer.flags))
        decodeNextSampleIfNeeded()
    }

    func dequeueOutputBuffer() -> VideoOutputWrapper? {
        assert(queue.isCurrent())
        guard framesInUse[framesReadCounter] == true else {
            return nil
        }

        framesInUse[framesReadCounter] = false
        framesReadCounter += 1
        if framesReadCounter >= .highWaterMark {
            framesReadCounter = 0
        }

        return decompressedSamplesQueue.dequeue()
    }

    func flush() {
        assert(queue.isCurrent())
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
        }
        _isDecodingSample = false
        _framedBeingDecoded = 0
        _pendingSamples.removeAll()
        buffersInUse = buffersInUse.map { _ in false }
        bufferCounter = 0
        framesInUse = framesInUse.map { _ in false }
        framesReadCounter = 0
        framesWriteCounter = 0
    }

    func release() {
        assert(queue.isCurrent())
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }
        buffers.forEach { $0.deallocate() }
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
        decodeSample(index: pending.0, sampleBuffer: pending.1, sampleFlags: pending.2)
    }

    private func decodeSample(index: Int, sampleBuffer: CMSampleBuffer, sampleFlags: SampleFlags) {
        assert(queue.isCurrent())
        if sampleFlags.contains(.endOfStream) {
            handleSample(response: .init(
                status: noErr,
                infoFlags: .init(),
                imageBuffer: nil,
                presentationTimeStamp: .zero,
                sampleIndex: index,
                sampleFlags: sampleFlags
            ))
        }

        guard let decompressionSession else { return }

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
                        sampleFlags: sampleFlags
                    )
                )
            }
        }

        if status != noErr {
            // TODO: error DecoderErrors.vtError(.init(rawValue: status))
//            _isDecodingSample = false
//            _framedBeingDecoded -= 1
//            decodeNextSampleIfNeeded()
        }
    }

    private func handleSample(response: VTDecoderResponce) {
        defer {
            _isDecodingSample = false
            _framedBeingDecoded -= 1
            decodeNextSampleIfNeeded()
        }

        do {
            guard response.status == noErr else {
                if !response.sampleFlags.contains(.endOfStream) {
                    assertionFailure()
                }
                return
            }

            buffersInUse[response.sampleIndex] = false
            framesInUse[response.sampleIndex] = true

            try decompressedSamplesQueue.enqueue(.init(
                imageBuffer: response.imageBuffer,
                sampleFlags: response.sampleFlags,
                presentationTime: response.presentationTimeStamp.microseconds
            ))
        } catch {
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

    func canReuseDecoder(oldFormat: CMFormatDescription?, newFormat: CMFormatDescription) -> Bool {
        assert(queue.isCurrent())
        guard let decompressionSession else { return false }
        let result = VTDecompressionSessionCanAcceptFormatDescription(
            decompressionSession,
            formatDescription: newFormat
        )
        if result { formatDescription = newFormat }
        return result
    }
}

extension VideoToolboxDecoder {
    struct VTDecoderResponce {
        let status: OSStatus
        let infoFlags: VTDecodeInfoFlags
        let imageBuffer: CVImageBuffer?
        let presentationTimeStamp: CMTime
        let sampleIndex: Int
        let sampleFlags: SampleFlags
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

final class VideoOutputWrapper: CoreVideoBuffer {
    let imageBuffer: CVImageBuffer?
    let sampleFlags: SampleFlags
    let presentationTime: Int64

    init(imageBuffer: CVImageBuffer?, sampleFlags: SampleFlags, presentationTime: Int64) {
        self.imageBuffer = imageBuffer
        self.sampleFlags = sampleFlags
        self.presentationTime = presentationTime
    }
}

private struct VideoToolboxCapabilitiesResolver: RendererCapabilities {
    let trackType: TrackType = .video

    func supportsFormat(_ format: CMFormatDescription) -> Bool {
        guard format.mediaType == .video else { return false }

        switch format.mediaSubType.rawValue {
        case kCMVideoCodecType_H264:
            return true
        default:
            return false
        }
    }
}

private extension Int {
    static let highWaterMark = 10
    static let defaultInputBufferSize: Int = 768 * 1024
}
