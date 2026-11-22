//
//  VTDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.08.2026.
//

import CoreMedia
import SEPlayerCommon
import VideoToolbox

/// A failure of the video decoder, as the status VideoToolbox gave.
enum VideoDecoderError: Error, CustomNSError {
    /// A sample came without the format to decode it with.
    case missingFormatDescription
    case failed(OSStatus)

    static var errorDomain: String { NSOSStatusErrorDomain }

    var errorCode: Int {
        switch self {
        case .missingFormatDescription: Int(kVTVideoDecoderBadDataErr)
        case let .failed(status): Int(status)
        }
    }
}

// TODO: add a real VideoDecoderFactory that makes this decoder, for apps that want decoded frames of the formats
// the system plays, and expose it in DefaultRenderersFactory.

/// A ``VideoDecoder`` on VideoToolbox, with a decompression session for each format it decodes.
final class VTDecoder: VideoDecoder {
    let name = "VideoToolbox"
    /// Whether the session decodes in hardware, which it does when the device has a decoder of the format.
    var isHardwareAccelerated: Bool {
        guard #available(iOS 17, tvOS 17, macCatalyst 17, *) else {
            return false
        }
        return copyProperty(kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder) as? Bool ?? false
    }

    private let decodeQueue: Queue
    private let outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    private var decompressionSession: VTDecompressionSession?

    private var currentInputFormatDescription: CMFormatDescription?
    /// Bumped by a flush: frames decoded for an older generation are dropped, so a flush needn't wait for them.
    private let generationLock = UnfairLock()
    private var generation: UInt64 = 0

    init(
        decodeQueue: Queue,
        outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    ) {
        self.decodeQueue = decodeQueue
        self.outputBufferQueue = outputBufferQueue
    }

    deinit {
        if let decompressionSession { VTDecompressionSessionInvalidate(decompressionSession) }
    }

    func getNumberOfFramesBeingDecoded() -> Int {
        copyProperty(kVTDecompressionPropertyKey_NumberOfFramesBeingDecoded) as? Int ?? 0
    }

    func getMinOutputPtsOfFramesBeingDecoded() -> CMTime {
        copyTimeProperty(kVTDecompressionPropertyKey_MinOutputPresentationTimeStampOfFramesBeingDecoded)
    }

    func getMaxOutputPtsOfFramesBeingDecoded() -> CMTime {
        copyTimeProperty(kVTDecompressionPropertyKey_MaxOutputPresentationTimeStampOfFramesBeingDecoded)
    }

    /// Reused when its session decodes the new format too, such as another resolution of the same codec. Another codec,
    /// or one the device has no decoder for, such as AV1 without hardware, needs a decoder the factory picks.
    func canReuse(oldFormat: AnyFormat, newFormat: AnyFormat) -> DecoderReuseResult {
        // Without a session nothing was decoded yet: a decoder of the new format costs nothing more.
        guard let decompressionSession, let description = try? newFormat.formatDescription() else {
            return .no
        }

        // Whether the decoder of the session decodes samples of the description too.
        let canAccept = VTDecompressionSessionCanAcceptFormatDescription(
            decompressionSession,
            formatDescription: description
        )
        return canAccept ? .yesWithoutReconfiguration : .no
    }

    func signalEndOfStream(_ completion: @escaping @Sendable () -> Void) {
        guard let decompressionSession else {
            completion()
            return
        }

        // Emits the frames the session holds back to reorder.
        VTDecompressionSessionFinishDelayedFrames(decompressionSession)
        // Blocks until the frames being decoded are out, which the output handler enqueues: not on the decode queue.
        DispatchQueue.global(qos: .userInitiated).async {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            completion()
        }
    }

    /// Drops the frames being decoded, without waiting for them.
    func flush() {
        SELogger.debug(.decoder, "Flushing the video decoder: frames being decoded are dropped")
        generationLock.withLock { generation &+= 1 }
    }

    /// Drops the frames being decoded and the session: the next frame, a keyframe, starts a new one.
    func invalidate() {
        flush()
        guard let decompressionSession else { return }
        SELogger.info(.decoder, "Invalidating the video decoder")
        VTDecompressionSessionInvalidate(decompressionSession)
        self.decompressionSession = nil
        currentInputFormatDescription = nil
    }

    func queueInputBuffer(_ buffer: CMSampleBuffer) throws {
        switch decompressionSession {
        case let .some(session):
            guard let currentFormat = currentInputFormatDescription,
                  let newFormat = buffer.formatDescription,
                  !currentFormat.equalTo(newFormat) else {
                break
            }

            let canAccept = VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat)
            SELogger.info(
                .decoder,
                "Video format changes to \(Self.describe(newFormat)): "
                    + (canAccept ? "the session goes on" : "a new session")
            )
            if !canAccept {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                fallthrough
            }
        case .none:
            guard let formatDescription = buffer.formatDescription else {
                throw VideoDecoderError.missingFormatDescription
            }

            try createDecompressionSession(with: formatDescription)
        }

        guard let decompressionSession else {
            throw VideoDecoderError.failed(kVTInvalidSessionErr)
        }

        let generation = generationLock.withLock { self.generation }
        let result = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: buffer,
            flags: ._EnableAsynchronousDecompression,
            infoFlagsOut: nil,
            outputHandler: { [weak self, outputBufferQueue] status, infoFlags, imageBuffer, pts, duration in
                if status != noErr {
                    SELogger.warning(.decoder, "Decoding the frame at \(pts.seconds) failed: \(status)")
                } else if infoFlags.contains(.frameDropped) {
                    SELogger.verbose(.decoder, "The decoder dropped the frame at \(pts.seconds)")
                }
                guard let imageBuffer, let self else { return }
                // Checked while enqueueing: a flush that comes in between empties the queue after this.
                self.generationLock.lock()
                defer { self.generationLock.unlock() }
                guard generation == self.generation else { return }

                do {
                    let sampleBuffer = try CMSampleBuffer(
                        imageBuffer: imageBuffer,
                        formatDescription: CMFormatDescription(imageBuffer: imageBuffer),
                        sampleTiming: CMSampleTimingInfo(
                            duration: duration,
                            presentationTimeStamp: pts,
                            decodeTimeStamp: .invalid
                        )
                    )
                    try outputBufferQueue.enqueue(sampleBuffer)
                } catch {
                    SELogger.warning(.decoder, "The decoded frame at \(pts.seconds) is dropped: \(error)")
                }
            }
        )

        if result != noErr {
            let time = buffer.presentationTimeStamp.seconds
            SELogger.warning(.decoder, "Submitting the frame at \(time) failed: \(result)")
            if result == kVTInvalidSessionErr || result == kVTVideoDecoderMalfunctionErr {
                // The system took the session away, as in the background: a new one starts at the next keyframe.
                invalidate()
            }
            throw VideoDecoderError.failed(result)
        }

        if buffer.bufferAttachments[.drainAfterDecoding] != nil {
            VTDecompressionSessionFinishDelayedFrames(decompressionSession)
        }
    }

    private func createDecompressionSession(with format: CMVideoFormatDescription) throws {
        var imageBufferAttributes: [CFString: Any] = [:]
        #if targetEnvironment(simulator)
        imageBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey] = [
            kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: true,
        ]
        #endif

        SELogger.info(.decoder, "Creating a video decoder for \(Self.describe(format))")
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &decompressionSession
        )
        guard status == noErr else { throw VideoDecoderError.failed(status) }

        currentInputFormatDescription = format
    }

    /// The value of a property of the session, or `nil` without a session or the property.
    private func copyProperty(_ key: CFString) -> CFTypeRef? {
        guard let decompressionSession else { return nil }
        var value: Unmanaged<CFTypeRef>?
        // Copies the value of the property into `value`, retained; returns `noErr` when the session has it.
        let status = VTSessionCopyProperty(decompressionSession, key: key, allocator: nil, valueOut: &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    private func copyTimeProperty(_ key: CFString) -> CMTime {
        guard let value = copyProperty(key), CFGetTypeID(value) == CFDictionaryGetTypeID() else {
            return .invalid
        }
        return CMTimeMakeFromDictionary(unsafeDowncast(value, to: CFDictionary.self))
    }

    private static func describe(_ format: CMFormatDescription) -> String {
        "\(format.mediaSubType) \(format.dimensions.width)×\(format.dimensions.height)"
    }
}
