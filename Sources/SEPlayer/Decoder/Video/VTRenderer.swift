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

    private var _isDecodingSample = false
    private var output: SEPlayerBufferView?
    private let outputSampleQueue: TypedCMBufferQueue<SampleReleaseWrapper>

    init(
        formatDescription: CMVideoFormatDescription,
        clock: CMClock,
        queue: Queue,
        displayLink: DisplayLinkProvider,
        sampleStream: SampleStream
    ) throws {
        self.formatDescription = formatDescription
        self.displayLink = displayLink
        outputSampleQueue = try TypedCMBufferQueue<SampleReleaseWrapper>(capacity: 10) { lhs, rhs in
            if lhs.releaseTime == rhs.releaseTime {
                return .compareEqualTo
            } else if lhs.releaseTime > rhs.releaseTime {
                return .compareGreaterThan
            } else {
                return .compareLessThan
            }
        }
        try super.init(
            clock: clock,
            queue: queue,
            sampleStream: sampleStream
        )

        videoFrameReleaseControl.enable(releaseFirstFrameBeforeStarted: true)
        videoFrameReleaseControl.setPlaybackSpeed(1.0)
        try initializeVideoDecoder()
    }

    override func start() {
        super.start()
        let elapsedRealtime = clock.microseconds
        videoFrameReleaseControl.start()
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
        displayLink.addOutput(output)
    }

    func removeBufferOutput(_ output: SEPlayerBufferView) {
        assert(queue.isCurrent())
        self.output = nil
        displayLink.removeOutput(output)
    }

    override func queueInputSample(sampleBuffer: CMSampleBuffer, completion: @escaping (Bool) -> Void) {
        assert(queue.isCurrent())
        guard let decompressionSession, !_isDecodingSample, !outputSampleQueue.isFull else { completion(false); return }

        _isDecodingSample = true
        let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        var infoFlagsOut: VTDecodeInfoFlags = []

        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            infoFlagsOut: &infoFlagsOut
        ) { [weak self] status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            guard let self else { return }
            self.queue.async {
                self.handleSample(
                    response: .init(
                        status: status,
                        infoFlags: infoFlags,
                        imageBuffer: imageBuffer,
                        presentationTimeStamp: presentationTimeStamp,
                        presentationDuration: presentationDuration
                    ),
                    completion: completion
                )
            }
        }

        if status != noErr {
            let error = VTDecoder.DecoderErrors.vtError(.init(rawValue: status), status)
            print(error)
        }
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
        guard !outputSampleQueue.isFull else { return false }
        let frameReleaseInfo = videoFrameReleaseControl.frameReleaseAction(
            presentationTime: presenationTime,
            position: position,
            elapsedRealtime: elapsedRealtime,
            outputStreamStartPosition: outputStreamStartPosition,
            isLastFrame: isLastOutputSample
        )

        if frameReleaseInfo.action == .immediately {
            Queues.mainQueue.async {
                self.output?.enqueueSampleImmideatly(sample)
            }

            videoFrameReleaseControl.didReleaseFrame()
            return true
        } else if frameReleaseInfo.action == .scheduled {
            try! outputSampleQueue.enqueue(.init(
                sample: sample, releaseTime: frameReleaseInfo.releaseTime
            ))
            videoFrameReleaseControl.didReleaseFrame()
            return true
        }

        return false
    }

    private func handleSample(response: VTDecoder.VTDecoderResponce, completion: @escaping (Bool) -> Void) {
        do {
            _isDecodingSample = false
            guard let imageBuffer = response.imageBuffer else {
                completion(false); return
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
            completion(true)
        } catch {
            completion(false)
        }
    }
}

extension VTRenderer: VideoFrameReleaseControl.FrameTimingEvaluator {
    func shouldForceReleaseFrame(earlyTime: Int64, elapsedSinceLastRelease: Int64) -> Bool {
        return earlyTime < -30_000 && elapsedSinceLastRelease > 100_000
    }

    func shouldDropFrame(earlyTime: Int64, elapsedSinceLastRelease: Int64, isLast: Bool) -> Bool {
        return false
    }

    func shouldIgnoreFrame(earlyTime: Int64, position: Int64, elapsedRealtime: Int64, isLast: Bool, treatDroppedAsSkipped: Bool) -> Bool {
        return false
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
            throw VTDecoder.DecoderErrors.vtError(.init(rawValue: status), status)
        }
    }
}

extension VTRenderer {
    final class SampleReleaseWrapper {
        let sample: CMSampleBuffer
        let releaseTime: Int64

        init(sample: CMSampleBuffer, releaseTime: Int64) {
            self.sample = sample
            self.releaseTime = releaseTime
        }
    }
}
