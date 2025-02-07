//
//  VTRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import AVFoundation
import VideoToolbox

final class VTRenderer: BaseSERenderer {
    private let formatDescription: CMVideoFormatDescription
    private var decompressionSession: VTDecompressionSession?
    private let displayLink: DisplayLinkProvider

    private lazy var videoFrameReleaseControl = VideoFrameReleaseControl(
        queue: queue,
        frameTimingEvaluator: self,
        clock: clock,
        displayLink: displayLink
    )

    private var output: SEPlayerBufferView?
    private let outputSampleQueue: TypedCMBufferQueue<CMSampleBuffer>

    private var _pendingSamples = [CMSampleBuffer]()
    private var _isDecodingSample = false
    private var _framedBeingDecoded = 0
    private var lastFrameReleaseTime: Int64 = .zero

    init(
        formatDescription: CMVideoFormatDescription,
        clock: CMClock,
        queue: Queue,
        displayLink: DisplayLinkProvider,
        sampleStream: SampleStream
    ) throws {
        self.formatDescription = formatDescription
        self.displayLink = displayLink
        outputSampleQueue = try TypedCMBufferQueue<CMSampleBuffer>(capacity: .highWaterMark)
        try super.init(
            clock: clock,
            queue: queue,
            sampleStream: sampleStream
        )

        _pendingSamples.reserveCapacity(.highWaterMark)
        videoFrameReleaseControl.enable(releaseFirstFrameBeforeStarted: true)
        try initializeVideoDecoder()
    }

    override func setPlaybackRate(new playbackRate: Float) {
        super.setPlaybackRate(new: playbackRate)
        videoFrameReleaseControl.setPlaybackSpeed(playbackRate)
    }

    override func start() {
        super.start()
        videoFrameReleaseControl.start()
        if let output { displayLink.addOutput(output) }
    }

    override func isReady() -> Bool {
        let isRendererReady = super.isReady()
        return videoFrameReleaseControl.isReady(isRendererReady: isRendererReady)
    }

    func setBufferOutput(_ output: SEPlayerBufferView) {
        assert(queue.isCurrent())
        Queues.mainQueue.async {
            output.setBufferQueue(self.outputSampleQueue)
        }
        self.output = output
    }

    func removeBufferOutput(_ output: SEPlayerBufferView) {
        assert(queue.isCurrent())
        self.output = nil
        displayLink.removeOutput(output)
    }

    override func queueInputSample(sampleBuffer: CMSampleBuffer) -> Bool {
        assert(queue.isCurrent())
        guard _framedBeingDecoded < .highWaterMark else { return false }
        _framedBeingDecoded += 1
        _pendingSamples.append(sampleBuffer)
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
        assert(queue.isCurrent())
        let presentationTime = presenationTime //- 33333
        guard outputSampleQueue.bufferCount < .highWaterMark - 1 else { return false }
        let frameReleaseAction = videoFrameReleaseControl.frameReleaseAction(
            presentationTime: presentationTime,
            position: position,
            elapsedRealtime: elapsedRealtime,
            outputStreamStartPosition: outputStreamStartPosition,
            isLastFrame: isLastOutputSample
        )

        switch frameReleaseAction {
        case .immediately:
            Queues.mainQueue.async { self.output?.enqueueSampleImmediately(sample) }
            videoFrameReleaseControl.didReleaseFrame()
            return true
        case .ignore:
            return true
        case .skip:
            return true
        case .drop:
            return true
        case .tryAgainLater:
            return false
        case let .scheduled(releaseTime):
            do {
                if releaseTime != lastFrameReleaseTime {
                    try! outputSampleQueue.enqueue(sample.nanoseconds(releaseTime))
                    videoFrameReleaseControl.didReleaseFrame()
                }
                lastFrameReleaseTime = releaseTime
                return true
            } catch {
                return false
            }
        }
    }
}

extension VTRenderer: VideoFrameReleaseControl.FrameTimingEvaluator {
    func shouldForceReleaseFrame(earlyTime: Int64, elapsedSinceLastRelease: Int64) -> Bool {
        return earlyTime < -30_000 && elapsedSinceLastRelease > 100_000
    }

    func shouldDropFrame(earlyTime: Int64, elapsedSinceLastRelease: Int64, isLast: Bool) -> Bool {
        return earlyTime < -30_000 && !isLast
    }

    func shouldIgnoreFrame(earlyTime: Int64, position: Int64, elapsedRealtime: Int64, isLast: Bool, treatDroppedAsSkipped: Bool) -> Bool {
        return (earlyTime < -500_000 && !isLast)
    }
}

private extension VTRenderer {
    private func initializeVideoDecoder() throws {
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
            throw DecoderErrors.vtError(.init(rawValue: status), status)
        }
    }

    private func decodeNextSampleIfNeeded() {
        guard !_isDecodingSample, !_pendingSamples.isEmpty else { return }

        _isDecodingSample = true
        let pendingSample = _pendingSamples.removeFirst()
        decodeSample(pendingSample)
    }

    private func decodeSample(_ sampleBuffer: CMSampleBuffer) {
        assert(queue.isCurrent())
        guard let decompressionSession else { return }

        var decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]

        if playbackRate <= 1.0 {
            decodeFlags.insert(._1xRealTimePlayback)
        }

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
                        presentationDuration: presentationDuration
                    )
                )
            }
        }

        if status != noErr {
            let error = DecoderErrors.vtError(.init(rawValue: status), status)
            _isDecodingSample = false
            _framedBeingDecoded -= 1
            decodeNextSampleIfNeeded()
        }
    }

    private func handleSample(response: VTDecoderResponce) {
        do {
            guard let imageBuffer = response.imageBuffer else {
                fatalError()
            }
            let formatDescription = try CMVideoFormatDescription(imageBuffer: imageBuffer)
            let timingInfo = CMSampleTimingInfo(
                duration: response.presentationDuration,
                presentationTimeStamp: response.presentationTimeStamp,
                decodeTimeStamp: response.presentationTimeStamp
            )
            let sampleBuffer = try CMSampleBuffer(
                imageBuffer: imageBuffer,
                formatDescription: formatDescription,
                sampleTiming: timingInfo
            )
            try decompressedSamplesQueue.enqueue(sampleBuffer)
        } catch {
            print(error)
        }
        _isDecodingSample = false
        _framedBeingDecoded -= 1
        decodeNextSampleIfNeeded()
    }
}

extension VTRenderer {
    struct VTDecoderResponce {
        let status: OSStatus
        let infoFlags: VTDecodeInfoFlags
        let imageBuffer: CVImageBuffer?
        let presentationTimeStamp: CMTime
        let presentationDuration: CMTime
    }

    enum DecoderErrors: Error, Equatable {
        case vtError(VTError?, OSStatus)
        case droppedFrame
        case decoderIsInvalidated
        case nothingToRead
        case decoderQueueIsFull

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

private extension CMItemCount {
    static let highWaterMark = 10
}
