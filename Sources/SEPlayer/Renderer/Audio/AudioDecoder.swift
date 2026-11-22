//
//  AudioDecoder.swift
//  SEPlayer
//

import CoreMedia
import SEPlayerCommon

/// Makes the audio decoders of the formats the system doesn't play, such as a software decoder.
///
/// The audio renderer gives the samples of a format the system plays to the audio output as they are. For a format
/// the system doesn't play, it asks its decoder factory, and plays the PCM audio a decoder of the factory makes.
public protocol AudioDecoderFactory {
    /// How the decoders of the factory support `format`.
    func supportsFormat(_ format: AnyFormat) -> RendererCapabilities.Support

    /// A decoder of `format`.
    ///
    /// - Parameters:
    ///   - format: The format of the samples to decode.
    ///   - mediaPeriodId: The period whose samples the decoder decodes first.
    ///   - decodeQueue: The queue the renderer calls the decoder on.
    ///   - outputBufferQueue: Where the decoder puts the decoded PCM audio, in presentation order.
    func createDecoder(
        format: AnyFormat,
        mediaPeriodId: MediaPeriodId?,
        decodeQueue: Queue,
        outputBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    ) throws -> AudioDecoder
}

/// Decodes compressed audio for the audio renderer.
public protocol AudioDecoder: AnyObject {
    /// The name of the decoder, for logs and analytics.
    var name: String { get }

    /// Queues a compressed packet, in decode order.
    func queueInputBuffer(_ buffer: CMSampleBuffer) throws
    /// Whether the decoder can go on decoding `newFormat` after `oldFormat`. A decoder that can't is drained, then
    /// released for a decoder of the new format.
    func canReuse(oldFormat: AnyFormat, newFormat: AnyFormat) -> DecoderReuseResult
    /// Calls `completion`, on any thread, once every packet queued before is decoded and in the output buffer queue.
    func signalEndOfStream(_ completion: @escaping @Sendable () -> Void)
    /// Drops the packets being decoded.
    func flush()
    /// Drops the packets being decoded and everything the decoder set up for its format.
    func invalidate()
}

public extension AudioDecoder {
    /// A decoder can't be reused by default: each format gets its own.
    func canReuse(oldFormat: AnyFormat, newFormat: AnyFormat) -> DecoderReuseResult { .no }
}
