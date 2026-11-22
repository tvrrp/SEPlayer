//
//  VideoDecoder.swift
//  SEPlayer
//

import CoreMedia
import SEPlayerCommon

/// Makes the video decoders of the formats the system doesn't play, such as a software VP8 or AV1 decoder.
///
/// The video renderer gives the samples of a format the system plays to the display as they are. For a format the
/// system doesn't play, it asks its decoder factory, and shows the frames a decoder of the factory makes.
public protocol VideoDecoderFactory {
    /// How the decoders of the factory support `format`.
    func supportsFormat(_ format: AnyFormat) -> RendererCapabilities.Support

    /// A decoder of `format`.
    ///
    /// - Parameters:
    ///   - format: The format of the samples to decode.
    ///   - mediaPeriodId: The period whose samples the decoder decodes first.
    ///   - decodeQueue: The queue the renderer calls the decoder on.
    ///   - outputBufferQueue: Where the decoder puts the decoded frames, in presentation order.
    func createDecoder(
        format: AnyFormat,
        mediaPeriodId: MediaPeriodId?,
        decodeQueue: Queue,
        outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    ) throws -> VideoDecoder
}

/// Decodes compressed video frames for the video renderer.
public protocol VideoDecoder: AnyObject {
    /// The name of the decoder, for logs and analytics.
    var name: String { get }
    /// Whether the decoder decodes in hardware.
    var isHardwareAccelerated: Bool { get }

    /// The number of frames queued and not yet decoded.
    func getNumberOfFramesBeingDecoded() -> Int
    /// The lowest presentation time of the frames being decoded, or `.invalid` without one.
    func getMinOutputPtsOfFramesBeingDecoded() -> CMTime
    /// The highest presentation time of the frames being decoded, or `.invalid` without one.
    func getMaxOutputPtsOfFramesBeingDecoded() -> CMTime

    /// Queues a compressed frame, in decode order.
    func queueInputBuffer(_ buffer: CMSampleBuffer) throws
    /// Whether the decoder can go on decoding `newFormat` after `oldFormat`. A decoder that can't is drained, then
    /// released for a decoder of the new format.
    func canReuse(oldFormat: AnyFormat, newFormat: AnyFormat) -> DecoderReuseResult
    /// Calls `completion`, on any thread, once every frame queued before is decoded and in the output buffer queue.
    func signalEndOfStream(_ completion: @escaping @Sendable () -> Void)
    /// Drops the frames being decoded; the next frame is a keyframe.
    func flush()
    /// Drops the frames being decoded and everything the decoder set up for its format, as after the system took the
    /// decoder away; the next frame is a keyframe.
    func invalidate()
}

public extension VideoDecoder {
    /// A decoder can't be reused by default: each format gets its own.
    func canReuse(oldFormat: AnyFormat, newFormat: AnyFormat) -> DecoderReuseResult { .no }
}
