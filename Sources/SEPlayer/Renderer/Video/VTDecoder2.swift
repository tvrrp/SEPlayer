//
//  VTDecoder2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.08.2026.
//

import CoreMedia
import SEPlayerCommon
import VideoToolbox

final class VTDecoder2 {
    private let decodeQueue: Queue
    private let outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    private var decompressionSession: VTDecompressionSession?

    private var playbackSpeed: Float = 1.0
    private var currentInputFormatDescription: CMFormatDescription?

    init(
        decodeQueue: Queue,
        outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    ) {
        self.decodeQueue = decodeQueue
        self.outputBufferQueue = outputBufferQueue
    }

    func getNumberOfFramesBeingDecoded() -> Int {
//        decoderGetProperty(
//            key: kVTDecompressionPropertyKey_NumberOfFramesBeingDecoded,
//            defaultValue: .zero
//        )
        guard let decompressionSession else { return .zero }

        var requestedValue: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(
            decompressionSession,
            key: kVTDecompressionPropertyKey_NumberOfFramesBeingDecoded,
            allocator: nil,
            valueOut: &requestedValue
        )

        if status == noErr,
           let requestedValue = requestedValue?.takeRetainedValue() as? Int {
            return requestedValue
        }

        return .zero
    }

    func getMinOutputPtsOfFramesBeingDecoded() -> CMTime {
        guard let decompressionSession else { return .invalid }

        var requestedValue: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(
            decompressionSession,
            key: kVTDecompressionPropertyKey_MinOutputPresentationTimeStampOfFramesBeingDecoded,
            allocator: nil,
            valueOut: &requestedValue
        )

        if status == noErr, let requestedValue {
            let dict = requestedValue.takeRetainedValue() as! CFDictionary
            return CMTimeMakeFromDictionary(dict)
        }

        return .invalid
    }

    func getMaxOutputPtsOfFramesBeingDecoded() -> CMTime {
//        decoderGetProperty(
//            key: kVTDecompressionPropertyKey_MaxOutputPresentationTimeStampOfFramesBeingDecoded,
//            defaultValue: .invalid
//        )
        guard let decompressionSession else { return .invalid }

        var requestedValue: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(
            decompressionSession,
            key: kVTDecompressionPropertyKey_MaxOutputPresentationTimeStampOfFramesBeingDecoded,
            allocator: nil,
            valueOut: &requestedValue
        )

        if status == noErr, let requestedValue {
            let dict = requestedValue.takeRetainedValue() as! CFDictionary
            return CMTimeMakeFromDictionary(dict)
        }

        return .invalid
    }

    func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
    }

    func flush() {
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
        }
    }

    func queueInputBuffer(buffer: CMSampleBuffer, flags: VTDecodeFrameFlags) throws {
        switch decompressionSession {
        case let .some(session):
            guard let currentFormat = currentInputFormatDescription,
                  let newFormat = buffer.formatDescription,
                  !currentFormat.equalTo(newFormat) else {
                break
            }

            if !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                fallthrough
            }
        case .none:
            guard let formatDescription = buffer.formatDescription else {
                fatalError()
            }

            try createDecompressionSession(with: formatDescription)
        }

        guard let decompressionSession else {
            fatalError()
        }

        let result = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: buffer,
            flags: flags.union(._EnableAsynchronousDecompression),
            infoFlagsOut: nil,
            outputHandler: { [outputBufferQueue] status, infoFlags, imageBuffer, pts, duration in
                guard let imageBuffer else { return }

                let formatDescription = try! CMFormatDescription(imageBuffer: imageBuffer)
                let sampleBuffer = try! CMSampleBuffer(
                    imageBuffer: imageBuffer,
                    formatDescription: formatDescription,
                    sampleTiming: CMSampleTimingInfo(
                        duration: duration,
                        presentationTimeStamp: pts,
                        decodeTimeStamp: .invalid
                    )
                )

                try! outputBufferQueue.enqueue(sampleBuffer)
            }
        )

        if result != noErr {
            fatalError()
        }

        if buffer.attachments.propagated[kCMSampleBufferAttachmentKey_DrainAfterDecoding as String] != nil {
            VTDecompressionSessionFinishDelayedFrames(decompressionSession)
        }
    }

    private func createDecompressionSession(with format: CMVideoFormatDescription) throws {
        var imageBufferAttributes: [CFString: Any] = [:]
#if targetEnvironment(simulator)
        imageBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey] = [
            kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: true
        ]
#endif

        try VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &decompressionSession
        ).validate()

        currentInputFormatDescription = format
    }

    private func decoderGetProperty<T>(key: CFString, defaultValue: T) -> T {
        guard let decompressionSession else { return defaultValue }

        var requestedValue: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(
            decompressionSession,
            key: key,
            allocator: nil,
            valueOut: &requestedValue
        )

        if status == noErr,
           let requestedValue = requestedValue?.takeRetainedValue() as? T {
            return requestedValue
        }

        return defaultValue
    }
}
