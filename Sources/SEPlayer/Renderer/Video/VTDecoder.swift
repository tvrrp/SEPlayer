//
//  TestVTDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.12.2025.
//

import Decoder
import VideoToolbox
import SEPlayerCommon

final class VTDecoder: SimpleDecoder<DecoderInputBuffer, VTDecoderOutputBuffer, VTDecoderErrors>, AVFDecoder {
    @UnfairLocked var currentOutputFormatDescription: CMFormatDescription?

    private var decompressionSession: VTDecompressionSession?
    private let format: Format
    private var playbackSpeed: Float = 1.0
    private var currentInputFormatDescription: CMFormatDescription?

    init(
        decodeQueue: Queue = Queues.sharedVideoDecodeQueue,
        format: Format,
        highWaterMark: Int = 5,
        initialInputBufferSize: Int? = nil
    ) throws {
        self.format = format
        try super.init(decodeQueue: decodeQueue, inputBuffersCount: highWaterMark, outputBuffersCount: highWaterMark)

        let initialInputBufferSize = format.maxInputSize > 0 ? format.maxInputSize : initialInputBufferSize
        if let initialInputBufferSize {
            try setInitialInputBufferSize(initialInputBufferSize)
        }

        try createDecoder(format: format)
    }

    static func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support.FormatSupport {
        let formatDescription = try format.buildFormatDescription()
        guard formatDescription.mediaType == .video else {
            return .unsupportedType
        }

        var decompressionSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &decompressionSession
        )

        let didCreateDecoder = decompressionSession != nil
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }

        return (status == noErr && didCreateDecoder) ? .handled : .unsupportedSubtype
    }

    override func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
    }

    override func createInputBuffer() -> DecoderInputBuffer {
        DecoderInputBuffer(bufferReplacementMode: .enabled)
    }

    override func createOutputBuffer() -> VTDecoderOutputBuffer {
        VTDecoderOutputBuffer { [unowned self] buffer in
            releaseOutputBuffer(buffer as! VTDecoderOutputBuffer)
        }
    }

    override func createDecodeError(_ error: Error) -> VTDecoderErrors {
        guard let error = error as? VTDecoderErrors else {
            return .unknownError(error)
        }

        return error
    }

    override func decode(
        inputBuffer: DecoderInputBuffer,
        outputBuffer: VTDecoderOutputBuffer,
        reset: Bool,
        isolation: isolated PlayerActor = #isolation
    ) async throws(VTDecoderErrors) {
        do {
            let formatDescription = try format.buildFormatDescription()
            guard let decompressionSession,
                  let sampleBuffer = try inputBuffer.sampleBuffer(formatDescription: formatDescription) else {
                throw VTDecoderErrors.missingData
            }

            if let currentInputFormatDescription, currentInputFormatDescription != formatDescription {
                self.currentOutputFormatDescription = nil
            }

            self.currentInputFormatDescription = formatDescription
            let shouldNotProduceFrame = !isAtLeastOutputStartTime(inputBuffer.time.presentationTimeStamp)
            let (pixelBuffer, pts, duration) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(CVPixelBuffer?, CMTime, CMTime), Error>) in
                var flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]

                if shouldNotProduceFrame {
                    flags.insert(._DoNotOutputFrame)
                } else if playbackSpeed <= 1 {
                    flags.insert(._1xRealTimePlayback)
                }

                let status = VTDecompressionSessionDecodeFrame(
                    decompressionSession,
                    sampleBuffer: sampleBuffer,
                    flags: flags,
                    infoFlagsOut: nil
                ) { status, flags, imageBuffer, pts, duration in
                    if status != noErr, ![.frameDropped, .frameInterrupted].contains(flags) {
                        continuation.resume(throwing: VTDecoderErrors.osStatus(.init(rawValue: status)))
                        return
                    }

                    continuation.resume(returning: (imageBuffer, pts, duration))
                }

                if status != noErr {
                    continuation.resume(throwing: VTDecoderErrors.osStatus(.init(rawValue: status)))
                }
            }

            switch shouldNotProduceFrame {
            case false:
                guard let pixelBuffer else { fallthrough }

                let _ = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate)
                outputBuffer.initialise(
                    pixelBuffer: pixelBuffer,
                    time: .init(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
                )
                if currentOutputFormatDescription == nil {
                    currentOutputFormatDescription = try CMFormatDescription(imageBuffer: pixelBuffer)
                }
            case true:
                outputBuffer.shouldBeSkipped = true
            }
        } catch {
            SELogger.error(.renderer, "VTDecoder unexpected error = \(error)")

            if let error = error as? VTDecoderErrors {
                throw error
            } else {
                throw .unknownError(error)
            }
        }
    }

    override func release() {
        super.release()
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
    }

    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool {
        guard let decompressionSession, let formatDescription = try? newFormat.buildFormatDescription() else {
            return false
        }

        return VTDecompressionSessionCanAcceptFormatDescription(
            decompressionSession,
            formatDescription: formatDescription
        )
    }

    private func createDecoder(format: Format) throws {
        let formatDescription = try format.buildFormatDescription()

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
            throw VTDecoderErrors.osStatus(.init(rawValue: status))
        }
    }
}

enum VTDecoderErrors: Error {
    case osStatus(VTError?)
    case unknownError(Error?)
    case missingData

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
        case videoDecoderBadData_1 = -12909
        case videoDecoderBadData_2 = -8969
        case videoDecoderUnsupportedDataFormat_1 = -12910
        case videoDecoderUnsupportedDataFormat_2 = -8970
        case videoDecoderMalfunction_1 = -12911
        case videoDecoderMalfunction_2 = -8960
        case videoDecoderNotAvailableNow = -12913
        case pixelRotationNotSupported = -12914
        case formatDescriptionChangeNotSupported = -12916
        case insufficientSourceColorData = -12917
        case couldNotCreateColorCorrectionData = -12918
        case colorSyncTransformConvertFailed = -12919
        case videoDecoderAuthorization = -12210
        case colorCorrectionPixelTransferFailed = -12212
        case couldNotFindTemporalFilter = -12217
        case pixelTransferNotPermitted = -12218
        case colorCorrectionImageRotationFailed = -12219
        case videoDecoderRemoved = -17690
        case sessionMalfunction = -17691
        case videoDecoderNeedsRosetta = -17692
        case videoDecoderReferenceMissing = -17694
        case videoDecoderCallbackMessaging = -17695
        case videoDecoderUnknown = -17696
        case extensionDisabled = -17697
        case couldNotOutputTaggedBufferGroup = -17699
        case couldNotFindExtension = -19510
        case extensionConflict = -19511
        case unknownError = -1
    }
}

extension DecoderInputBuffer {
    func sampleBuffer(formatDescription: CMFormatDescription) throws -> CMSampleBuffer? {
        let data = try dequeue()
        guard size > 0 else { return nil }

        let blockBuffer = try CMBlockBuffer(buffer: data[0..<size], deallocator: { _, _ in })

        let sampleTimings = !flags.contains(.endOfStream) ? [time] : []
        let sampleSizes = !flags.contains(.endOfStream) ? [size] : []

        return try CMSampleBuffer(
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            numSamples: 1,
            sampleTimings: sampleTimings,
            sampleSizes: sampleSizes
        )
    }
}

final class VTDecoderOutputBuffer: SimpleDecoderOutputBuffer {
    var pixelBuffer: CVPixelBuffer?

    func initialise(pixelBuffer: CVPixelBuffer, time: CMSampleTimingInfo) {
        self.pixelBuffer = pixelBuffer
        self.time = time
    }

    override func release() {
        pixelBuffer = nil
        super.release()
    }

    override func clear() {
        super.clear()
        pixelBuffer = nil
    }
}
