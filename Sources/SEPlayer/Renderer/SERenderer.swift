//
//  SERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import CoreMedia
import SEPlayerCommon
import VideoToolbox

public protocol SERendererDelegate: AnyObject {
    func rendererReportsReady(_ renderer: SERenderer)
    func rendererNeedsMoreData(_ renderer: SERenderer)
    func rendererDidFinishReading(_ renderer: SERenderer)
    func rendererDidFinishRendering(_ renderer: SERenderer)
    func onRendererError(_ renderer: SERenderer, error: SEPlaybackError)
}

public protocol SERenderer: AnyObject {
    var trackType: TrackType { get }
    var delegate: SERendererDelegate? { get set }
    func handleMessage(_ message: RendererMessage) throws
    func getCapabilities() -> RendererCapabilitiesResolver

    func getMediaClock() -> MediaClock?
    func getTimebase() -> CMTimebase?
    func getState() -> SERendererState
    func enable(
        formats: [Format],
        stream: TriggerableSampleStream,
        position: CMTime,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws

    func start() throws

    func replaceStream(
        formats: [Format],
        stream: TriggerableSampleStream,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws
    func getStream() -> TriggerableSampleStream?
    func didReadStreamToEnd() -> Bool
    func getReadingPosition() -> CMTime
    func setStreamFinal()
    func isCurrentStreamFinal() -> Bool
    func resetPosition(new position: CMTime) throws
    func setPlaybackSpeed(current: Float, target: Float) throws
    func enableRenderStartOfStream()
    func getTimeline() -> Timeline
    func setTimeline(_ timeline: Timeline)
    func render(position: CMTime, elapsedRealtime: CMTime) throws
    func isReady() -> Bool
    func isEnded() -> Bool
    func stop()
    func disable()
    func reset()
    func release()
}

@frozen
public enum SERendererState {
    case disabled
    case enabled
    case started
}

enum CodecInputRequestResult<T> {
    case haveData(buffer: T, isRealtime: Bool, shouldDrop: Bool)
    case noDataNow
    case endOfStream
}

enum CodecOutputStatus {
    case haveData
    case inputRanDry
    case endOfStream
}

//protocol SECodecDelegate<OutputBuffer>: AnyObject {
//    associatedtype OutputBuffer
//    var isolation: PlayerActor { get }
//    func didConvert(_ outputBuffer: OutputBuffer, isolation: isolated PlayerActor)
//}

protocol SECodec: AnyObject {
    associatedtype InputBuffer: AnyObject
    associatedtype OutputBuffer

    typealias InputByfferRequest = (numberOfSamples: Int, decodedDuration: CMTime)

//    var delegate: SECodecDelegate<OutputBuffer>? { get set }
    var isolation: PlayerActor { get }
    var inputFormat: CMFormatDescription? { get }
    var outputFormat: CMFormatDescription? { get }
    var inFlightSamples: Int { get }
    var inFlightSamplesMinOutputPts: CMTime { get }
    var inFlightSamplesMaxOutputPts: CMTime { get }

    /// Convert provided buffer to output format
    /// - Parameters:
    ///   - bufferProvider: closure that will be called to provide compressed sample buffers.
    ///         Closure can be called multiple times to accomodate decoding request.
    ///         Input is number of samples, that decoder ask to provide in the single run. Can be less or more.
    ///   - outputBufferProvider: closure that will be called to provide outputBuffers for decoder to decode samples to.
    ///         Ask how many bytes must be
    ///         Each decoder specifies which output buffer is requested.
    ///         Some decoders will never ask for output buffer and instead will create them internally (for example some video decoders)
    ///   - isolation: `Actor` that will run decode operation
    func convert(
        inputBufferProvider: (InputByfferRequest) throws -> CodecInputRequestResult<InputBuffer>,
        isolation: isolated PlayerActor
    ) async throws

    func finishDelayedSamples(isolation: isolated PlayerActor)
    func waitForAsynchronousSamples(isolation: isolated PlayerActor)
}

protocol SERendererSinkDelegate: AnyObject {
    associatedtype Sink: SERendererSink
    nonisolated var isolation: PlayerActor { get }
    func rendererSink(_ sink: Sink, didFailedWith error: Error?, isolation: isolated any Actor)
}

protocol SERendererSink {
    associatedtype OutputBuffer

    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }
    func enqueue(_ buffer: OutputBuffer)
    func flush()
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
    func stopRequestingMediaData()
}

protocol SEVideoRendererSink: SERendererSink where OutputBuffer == CMSampleBuffer {
    func setControlTimebase(_ timebase: CMTimebase?)
    func flush(removeImage: Bool)
    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation)
}

protocol SEVideoRendererCodecDelegate: AnyObject {
    var isolation: PlayerActor { get }
    func didConvert(_ outputBuffer: CMSampleBuffer, isolation: isolated PlayerActor)
}

protocol SEVideoRendererCodec: SECodec where InputBuffer == CMSampleBuffer, OutputBuffer == CMSampleBuffer {
    var delegate: SEVideoRendererCodecDelegate? { get set }
}

class SEVideoRenderer<Codec: SEVideoRendererCodec, VideoSink: SEVideoRendererSink> {
    let isolation: PlayerActor

    private let queue: Queue
    private let videoSink: VideoSink
    private let outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    private var codec: Codec?

    private var lowWaterMark: CMTime = .invalid
    private var highWaterMark: CMTime = .invalid

    init(
        queue: Queue,
        videoSink: VideoSink
    ) throws {
        self.queue = queue
        isolation = queue.playerActor()
        self.videoSink = videoSink
        outputBufferQueue = try .init()
    }

    func render(inputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>) {
        Task {
            do {
                guard let codec else { return }
                codec.delegate = self
                let condition = try outputBufferQueue.installTrigger(condition: .whenDurationBecomesLessThan(highWaterMark))

                try await codec.convert(
                    inputBufferProvider: {
                        try provideCodecInput(
                            from: inputBufferQueue,
                            codec: codec,
                            requestNumberOfSample: $0,
                            convertedDuration: $1,
                            condition: condition
                        )
                    },
                    isolation: codec.isolation
                )
            } catch {

            }
        }
    }

    private func provideCodecInput(
        from inputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>,
        codec: Codec,
        requestNumberOfSample: Int,
        convertedDuration: CMTime,
        condition: CMBufferQueue.TriggerToken
    ) throws -> CodecInputRequestResult<CMSampleBuffer> {
        guard inputBufferQueue.testTrigger(condition) else {
            return .noDataNow
        }

        if inputBufferQueue.isAtEndOfData {
            return .endOfStream
        }

        if inputBufferQueue.isEmpty {
            return .noDataNow
        }

        guard let sampleBuffer = inputBufferQueue.dequeue() else {
            return .noDataNow
        }

        try sampleBuffer.makeDataReady()

        return .haveData(buffer: sampleBuffer, isRealtime: true, shouldDrop: false)
    }
}

extension SEVideoRenderer: SEVideoRendererCodecDelegate {
    func didConvert(_ outputBuffer: CMSampleBuffer, isolation: isolated PlayerActor) {
        assert(queue.isCurrent())
        do {
            try outputBufferQueue.enqueue(outputBuffer)
        } catch {

        }
    }
}

final class VTDecoder2: SEVideoRendererCodec {
    typealias InputBuffer = CMSampleBuffer
    typealias OutputBuffer = CMSampleBuffer

    weak var delegate: (any SEVideoRendererCodecDelegate)? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    var inputFormat: CMFormatDescription? {
        get { lock.withLock { _inputFormat } }
    }

    var outputFormat: CMFormatDescription? {
        get { lock.withLock { _outputFormat } }
    }

    var inFlightSamples: Int { getInFlightSamples() }
    var inFlightSamplesMinOutputPts: CMTime { getInFlightSamplesPts(lookForMinPts: true) }
    var inFlightSamplesMaxOutputPts: CMTime { getInFlightSamplesPts(lookForMinPts: false) }

    let isolation: PlayerActor

    private let queue: Queue
    private let lock: UnfairLock

    private weak var _delegate: (any SEVideoRendererCodecDelegate)?
    private var decompressionSession: VTDecompressionSession?
    private var _inputFormat: CMFormatDescription?
    private var _outputFormat: CMFormatDescription?
    private var previousError: Error?

    init(queue: Queue = Queues.sharedVideoDecodeQueue) {
        self.queue = queue
        self.isolation = queue.playerActor()
        lock = UnfairLock()
    }

    func convert(
        inputBufferProvider: (InputByfferRequest) throws -> CodecInputRequestResult<CMSampleBuffer>,
        isolation: isolated PlayerActor
    ) async throws {
        if let previousError {
            throw previousError
        }

        let inFlightDuration = inFlightSamplesMaxOutputPts - inFlightSamplesMinOutputPts
        switch try inputBufferProvider((1, inFlightDuration)) {
        case let .haveData(sampleBuffer, isRealtime, shouldDrop):
            guard let format = sampleBuffer.formatDescription else {
                throw ErrorBuilder(errorDescription: "")
            }

            let decompressionSession = try createDecoderIfNeeded(format: format)

            var decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
            if isRealtime { decodeFlags.insert(._1xRealTimePlayback) }
            if shouldDrop { decodeFlags.insert(._DoNotOutputFrame) }

            let result = VTDecompressionSessionDecodeFrame(
                decompressionSession,
                sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: nil,
                outputHandler: { [weak self] status, flags, imageBuffer, pts, duration in
                    Task {
                        await self?.finishFrame(status, flags, imageBuffer, pts, duration, shouldDrop, isolation)
                    }
                }
            )

            if result != noErr {
                throw VTDecoderErrors.osStatus(.init(rawValue: result))
            }

            try await convert(inputBufferProvider: inputBufferProvider, isolation: isolation)
        case .endOfStream:
            finishDelayedSamples(isolation: isolation)
        case .noDataNow:
            return
        }
    }

    func flush(isolation: isolated PlayerActor) async throws {
        await waitForAsynchronousSamples(isolation: isolation)
        previousError = nil
    }

    func finishDelayedSamples(isolation: isolated PlayerActor) {
        guard let decompressionSession else { return }
        VTDecompressionSessionFinishDelayedFrames(decompressionSession)
    }

    func waitForAsynchronousSamples(isolation: isolated PlayerActor) {
        guard let decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
    }

    private func createDecoderIfNeeded(format: CMFormatDescription) throws -> VTDecompressionSession {
        if let decompressionSession {
            if let inputFormat, inputFormat === format {
                return decompressionSession
            }

            if VTDecompressionSessionCanAcceptFormatDescription(decompressionSession, formatDescription: format) {
                return decompressionSession
            }
        }

        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }

        var imageBufferAttributes: [NSString: Any] = [:]
        #if targetEnvironment(simulator)
        imageBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey as NSString] = [
            kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: true
        ]
        #endif
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &decompressionSession
        )

        if status != noErr {
            throw VTDecoderErrors.osStatus(.init(rawValue: status))
        }

        guard let decompressionSession else {
            throw ErrorBuilder(errorDescription: "")
        }

        lock.withLock { _inputFormat = format }
        return decompressionSession
    }

    private func finishFrame(
        _ status: OSStatus,
        _ flags: VTDecodeInfoFlags,
        _ pixelBuffer: CVImageBuffer?,
        _ pts: CMTime,
        _ duration: CMTime,
        _ shouldNotProduceFrame: Bool,
        _ isolation: isolated PlayerActor
    ) async {
        do {
            if status != noErr, ![.frameDropped, .frameInterrupted].contains(flags) {
                throw VTDecoderErrors.osStatus(.init(rawValue: status))
            }

            guard let delegate else { return }
            switch shouldNotProduceFrame {
            case false:
                guard let pixelBuffer else { fallthrough }

                let sampleBuffer = try CMSampleBuffer(
                    imageBuffer: pixelBuffer,
                    formatDescription: CMVideoFormatDescription(imageBuffer: pixelBuffer),
                    sampleTiming: CMSampleTimingInfo(
                        duration: duration,
                        presentationTimeStamp: pts,
                        decodeTimeStamp: .invalid
                    )
                )

                await delegate.didConvert(sampleBuffer, isolation: delegate.isolation)
            case true:
//                outputBuffer.shouldBeSkipped = true
                return
            }
        } catch {
            previousError = error
        }
    }

    private func getInFlightSamples() -> Int {
        guard let session = lock.withLock({ decompressionSession }) else {
            return .zero
        }

        var value: CFNumber?
        let status = VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_NumberOfFramesBeingDecoded,
            allocator: nil,
            valueOut: &value
        )

        guard status == noErr, let value else {
            return .zero
        }

        return Int(value)
    }

    private func getInFlightSamplesPts(lookForMinPts: Bool) -> CMTime {
        guard let session = lock.withLock({ decompressionSession }) else {
            return .invalid
        }

        let key = if lookForMinPts {
            kVTDecompressionPropertyKey_MinOutputPresentationTimeStampOfFramesBeingDecoded
        } else {
            kVTDecompressionPropertyKey_MaxOutputPresentationTimeStampOfFramesBeingDecoded
        }

        var value: CFDictionary?
        let status = VTSessionCopyProperty(
            session,
            key: key,
            allocator: nil,
            valueOut: &value
        )

        guard status == noErr, let value else {
            return .invalid
        }

        return CMTimeMakeFromDictionary(value)
    }

    enum DecoderErrors: Error {

    }
}

final class TestVideoSink: SEVideoRendererSink {
    func setControlTimebase(_ timebase: CMTimebase?) {

    }
    
    func flush(removeImage: Bool) {

    }
    
    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {

    }
    
    let isReadyForMoreMediaData: Bool = false

    let hasSufficientMediaDataForReliablePlaybackStart: Bool = false

    func enqueue(_ buffer: CMSampleBuffer) {

    }
    
    func flush() {

    }
    
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {

    }
    
    func stopRequestingMediaData() {

    }
    

}

//protocol SEAudioCodecDelegate: SECodecDelegate {
//    func provideOutputBuffer(isolation: isolated PlayerActor) -> OutputBuffer
//}

//protocol SEAudioCodec: SECodec where Delegate: SEAudioCodecDelegate {}


final class StorageTest {
    private let renderer: SEVideoRenderer<VTDecoder2, TestVideoSink>

    init(renderer: SEVideoRenderer<VTDecoder2, TestVideoSink>) {
        self.renderer = renderer
    }
}
