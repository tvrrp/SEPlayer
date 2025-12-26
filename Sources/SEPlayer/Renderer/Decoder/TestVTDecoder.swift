//
//  TestVTDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.12.2025.
//

import VideoToolbox

final class TestDecoderInputBuffer: SimpleDecoderInputBuffer {
    enum BufferReplacementMode {
        case disabled
        case enabled
    }

    var data: UnsafeMutableRawBufferPointer? {
        guard let _data else { return nil }
        return UnsafeMutableRawBufferPointer(rebasing: _data[position...])
    }

    var format: Format?
    var size: Int = .zero
    var flags: SampleFlags = []
    var timeUs: Int64 = .zero

    private let bufferReplacementMode: BufferReplacementMode
    private let paddingSize: Int

    private var _data: UnsafeMutableRawBufferPointer?
    private var position: Int = 0

    static func noDataBuffer() -> TestDecoderInputBuffer {
        TestDecoderInputBuffer(bufferReplacementMode: .disabled)
    }

    init(bufferReplacementMode: BufferReplacementMode, paddingSize: Int = 0) {
        self.bufferReplacementMode = bufferReplacementMode
        self.paddingSize = paddingSize
    }

    func ensureSpaceForWrite(_ size: Int) throws {
        let size = size + paddingSize
        if _data == nil {
            _data = try createReplacementBuffer(requiredCapacity: size)
            return
        }

        guard let data = _data else { return }
        let capacity = data.count
        let requiredCapacity = position + size

        guard capacity < requiredCapacity else {
            return
        }

        let newData = try createReplacementBuffer(requiredCapacity: requiredCapacity)
        if position > 0 {
            newData.copyBytes(from: data[0..<position])
        }
        _data?.deallocate()
        _data = newData
    }

    func clear() {
        flags = []
    }

    func sampleBuffer() throws -> CMSampleBuffer? {
        guard let formatDescription = try format?.buildFormatDescription(),
              let data, size > 0 else {
            return nil
        }

        let blockBuffer = try CMBlockBuffer(
            length: size,
            allocator: { _ in
                data.baseAddress
            },
            deallocator: { (_, _) in }
        )

        let sampleTiming = CMSampleTimingInfo(
            duration: CMTime.from(microseconds: timeUs),
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )

        let sampleTimings = !flags.contains(.endOfStream) ? [sampleTiming] : []
        let sampleSizes = !flags.contains(.endOfStream) ? [size] : []

        return try CMSampleBuffer(
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            numSamples: 1,
            sampleTimings: sampleTimings,
            sampleSizes: sampleSizes
        )
    }

    private func createReplacementBuffer(requiredCapacity: Int) throws -> UnsafeMutableRawBufferPointer {
        switch bufferReplacementMode {
        case .enabled:
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: requiredCapacity)
            buffer.initialize(repeating: .zero)
            return UnsafeMutableRawBufferPointer(buffer)
        case .disabled:
            throw AllocationFailed(
                currentCapacity: data?.count ?? .zero,
                requiredCapacity: requiredCapacity
            )
        }
    }

    struct AllocationFailed: Error {
        let currentCapacity: Int
        let requiredCapacity: Int
    }
}

final class VTDecoderOutputBuffer: SimpleDecoderOutputBuffer {
    var flags: SampleFlags = []
    var timeUs: Int64 = .zero
    var shouldBeSkipped: Bool = false
    var skippedOutputBufferCount: Int = .zero
    var pixelBuffer: CVPixelBuffer?

    func initialise(pixelBuffer: CVPixelBuffer, timeUs: Int64) {
        self.pixelBuffer = pixelBuffer
        self.timeUs = timeUs
    }

    func release() {
        pixelBuffer = nil
    }

    func clear() {
        pixelBuffer = nil
    }
}

final class TestVTDecoder: SimpleDecoder<TestDecoderInputBuffer, VTDecoderOutputBuffer, VTDecoderErrors> {
    private var decompressionSession: VTDecompressionSession?
    private var lastFormatDescription: CMFormatDescription?
    private var playbackSpeed: Float = 1.0

    init(
        decodeQueue: Queue = Queues.videoDecodeQueue,
        highWaterMark: Int = 10,
        initialInputBufferSize: Int
    ) throws {
        super.init(decodeQueue: decodeQueue, inputBuffersCount: highWaterMark, outputBuffersCount: highWaterMark)
        try setInitialInputBufferSize(initialInputBufferSize)
    }

    override func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
    }

    override func createInputBuffer() -> TestDecoderInputBuffer {
        TestDecoderInputBuffer(bufferReplacementMode: .enabled)
    }

    override func createOutputBuffer() -> VTDecoderOutputBuffer {
        VTDecoderOutputBuffer()
    }

    override func createDecodeError(_ error: Error) -> VTDecoderErrors {
        guard let error = error as? VTDecoderErrors else {
            return .unknownError(error)
        }

        return error
    }

    override func decode(
        inputBuffer: TestDecoderInputBuffer,
        outputBuffer: VTDecoderOutputBuffer,
        reset: Bool,
        isolation: isolated PlayerActor = #isolation
    ) async throws(VTDecoderErrors) {
        do {
            guard let formatDescription = try inputBuffer.format?.buildFormatDescription(),
                  let sampleBuffer = try inputBuffer.sampleBuffer() else {
                throw VTDecoderErrors.missingData
            }

            try createDecoderIfNeeded(formatDescription: formatDescription)
            guard let decompressionSession else {
                throw VTDecoderErrors.missingData
            }

            let shouldNotProduceFrame = isAtLeastOutputStartTimeUs(inputBuffer.timeUs)
            let pixelBuffer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CVPixelBuffer?, Error>) in
                let flags: VTDecodeFrameFlags = if shouldNotProduceFrame {
                    [._DoNotOutputFrame]
                } else if playbackSpeed <= 1 {
                    [._1xRealTimePlayback]
                } else {
                    []
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

                    continuation.resume(returning: imageBuffer)
                }

                if status != noErr {
                    continuation.resume(throwing: VTDecoderErrors.osStatus(.init(rawValue: status)))
                }
            }

            switch shouldNotProduceFrame {
            case true:
                guard let pixelBuffer else { fallthrough }

                let marker = Marker { [weak self] in
                    await self?.releaseOutputBuffer(outputBuffer, isolation: isolation)
                }

                CVBufferSetAttachment(pixelBuffer, "VTDecoder Marker" as CFString, marker, .shouldNotPropagate)
                outputBuffer.initialise(pixelBuffer: pixelBuffer, timeUs: inputBuffer.timeUs)
            case false:
                outputBuffer.shouldBeSkipped = true
            }
        } catch {
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

    private func createDecoderIfNeeded(formatDescription: CMFormatDescription) throws {
        if let decompressionSession, let lastFormatDescription, !lastFormatDescription.equalTo(formatDescription),
           !VTDecompressionSessionCanAcceptFormatDescription(decompressionSession, formatDescription: formatDescription) {
            VTDecompressionSessionFinishDelayedFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }

        guard decompressionSession == nil else { return }

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

extension TestVTDecoder {
    final class Marker {
        private let deinitClosure: @isolated(any) () async -> Void

        init(deinitClosure: sending @escaping @isolated(any) () async -> Void) {
            self.deinitClosure = deinitClosure
        }

        deinit {
            let deinitClosure = deinitClosure
            Task { await deinitClosure() }
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
        case unknownError = -1
    }
}
