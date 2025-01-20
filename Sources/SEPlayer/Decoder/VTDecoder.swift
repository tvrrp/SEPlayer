//
//  VideoToolboxDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VTDecoder: SEDecoder {
    var isReadyForMoreMediaData: Bool {
        get {
            decoderQueue.sync { !_isDecodingSample && decompressedSamplesQueue.bufferCount <= .highWaterMark }
        }
    }

    private var decompressionSession: VTDecompressionSession?
    private let sampleStream: SampleStream
    private let decoderQueue: Queue
    private let returnQueue: Queue
    private let formatDescription: CMVideoFormatDescription
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
        self.formatDescription = formatDescription
        self.sampleStream = sampleStream
        self.decoderQueue = decoderQueue
        self.returnQueue = returnQueue
        self.complessedSampleQueue = try TypedCMBufferQueue<CMSampleBuffer>(
            capacity: .maximumCapacity,
            handlers: .unsortedSampleBuffers
        )
        self.decompressedSamplesQueue = decompressedSamplesQueue

        try initializeVideoDecoder()
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
                enqueueSample(sampleBuffer: buffer, displaying: enqueueDecodedSample) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        returnQueue.async { completion(error) }
                        return
                    }

                    returnQueue.async {
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
        }
    }

    func invalidate() {
        decoderQueue.sync {
            flush()
            isInvalidated = true
            if let decompressionSession {
                VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
                VTDecompressionSessionInvalidate(decompressionSession)
            }
        }
    }
}

private extension VTDecoder {
    private func initializeVideoDecoder() throws {
        var imageBufferAttributes: [NSString: Any] = [:]
        #if targetEnvironment(simulator)
        imageBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey as NSString] = [
            kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: true
        ]
        #endif

        var outputCallbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: nil,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &outputCallbackRecord,
            decompressionSessionOut: &decompressionSession
        )

        if status != noErr {
            throw DecoderErrors.vtError(.init(rawValue: status), status)
        }
    }
}

private extension VTDecoder {
    func enqueueSample(sampleBuffer: CMSampleBuffer, displaying: Bool, completion: @escaping (Error?) -> Void) {
        decoderQueue.async { [self] in
            decodeNextSample(sampleBuffer: sampleBuffer, displaying: displaying) { [weak self] error in
                self?.returnQueue.async { completion(error) }
            }
        }
    }

    func decodeNextSample(sampleBuffer: CMSampleBuffer, displaying: Bool, completion: @escaping (Error?) -> Void) {
        assert(decoderQueue.isCurrent())
        _isDecodingSample = true
        _samplesInDecode = sampleBuffer.numSamples

        decodeSample(sampleBuffer: sampleBuffer, displaying: displaying) { [weak self] result in
            guard let self else { return }
            assert(decoderQueue.isCurrent())

            _lastDecodingError = nil
            _totalVideoFrames += 1

            switch result {
            case let .success(decoderResponse):
                guard !decoderResponse.infoFlags.contains(.frameDropped) else {
                    _totalDroppedVideoFrames += 1
                    completion(DecoderErrors.droppedFrame)
                    return
                }
                
                guard decoderResponse.status == noErr, let imageBuffer = decoderResponse.imageBuffer else {
                    _corruptedVideoFrames += 1
                    completion(DecoderErrors
                        .vtError(.init(rawValue: decoderResponse.status), decoderResponse.status)
                    )
                    return
                }
                
                guard displaying else { return }
                
                do {
                    let formatDescription = try CMVideoFormatDescription(imageBuffer: imageBuffer)
                    let timingInfo = CMSampleTimingInfo(
                        duration: decoderResponse.presentationDuration,
                        presentationTimeStamp: decoderResponse.presentationTimeStamp,
                        decodeTimeStamp: decoderResponse.presentationTimeStamp
                    )

                    let sampleBuffer = try CMSampleBuffer(
                        imageBuffer: imageBuffer,
                        formatDescription: formatDescription,
                        sampleTiming: timingInfo
                    )

                    enqueueDecodedSample(sample: sampleBuffer, completion: completion)
                } catch {
                    _corruptedVideoFrames += 1
                    _lastDecodingError = error
                    completion(error)
                    return
                }
            case let .failure(error):
                completion(error)
            }
        }
    }

    private func decodeSample(sampleBuffer: CMSampleBuffer, displaying: Bool, completion: @escaping (Result<VTDecoderResponce, DecoderErrors>) -> Void) {
        guard let decompressionSession else { return }

        print("Video New sample!!!, pts = \(sampleBuffer.presentationTimeStamp.seconds)")
        var infoFlagsOut: VTDecodeInfoFlags = []

        var flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        if !displaying { flags.insert(._DoNotOutputFrame) }

        let decoderQueue = decoderQueue
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: flags,
            infoFlagsOut: &infoFlagsOut
        ) { status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            decoderQueue.async {
                completion(.success(
                    .init(status: status, infoFlags: infoFlags, imageBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp, presentationDuration: presentationDuration)
                ))
            }
        }

        if status != noErr {
            _isDecodingSample = false
            _samplesInDecode = 0
            _corruptedVideoFrames += 1
            let error = DecoderErrors.vtError(.init(rawValue: status), status)
            completion(.failure(error))
            print(error)
        }
    }
}

private extension VTDecoder {
    func enqueueDecodedSample(sample: CMSampleBuffer, completion: @escaping (Error?) -> Void) {
        assert(decoderQueue.isCurrent())
        guard !isInvalidated else { completion(DecoderErrors.decoderIsInvalidated); return }

        do {
            try decompressedSamplesQueue.enqueue(sample)
            _samplesInDecode -= 1
            if _samplesInDecode == 0 {
                _isDecodingSample = false
                returnQueue.async { self.didProducedSample?() }
                completion(nil)
            }
        } catch {
            _totalDroppedVideoFrames += 1
            _samplesInDecode -= 1
            if _samplesInDecode == 0 {
                _isDecodingSample = false
            }
            completion(error)
        }
    }
}

extension VTDecoder {
    private struct VTDecoderResponce {
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
    static let maximumCapacity = 120
    static let highWaterMark = 30
    static let lowWaterMark = 15
    static let maxDecodingFrames = 10
}
