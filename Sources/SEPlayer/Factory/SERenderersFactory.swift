//
//  SERenderersFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

import AVFoundation
import SEPlayerCommon
import VideoToolbox

public protocol RenderersFactory {
    /// The synchronizer that runs the clock of the renderers this factory makes.
    func makeSynchronizer() -> any PlaybackSynchronizer
    func createRenderers(
        queue: Queue,
        clock: SEClock,
        renderSynchronizer: any PlaybackSynchronizer,
        textOutput: TextOutput,
        videoListener: VideoRendererEventListener,
        audioListener: AudioRendererEventListener
    ) -> [any SERenderer]
}

public extension RenderersFactory {
    func makeSynchronizer() -> any PlaybackSynchronizer { AVSampleBufferRenderSynchronizer() }
}

/// Makes renderers on AVFoundation's sample buffer renderers: `AVSampleBufferAudioRenderer` and
/// `AVSampleBufferDisplayLayer`, in an `AVSampleBufferRenderSynchronizer`.
public struct DefaultRenderersFactory: RenderersFactory {
    public init() {
#if os(macOS)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
#elseif targetEnvironment(macCatalyst)
        typealias RegisterFn = @convention(c) (CMVideoCodecType) -> Void
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "VTRegisterSupplementalVideoDecoderIfAvailable") {
            unsafeBitCast(sym, to: RegisterFn.self)(kCMVideoCodecType_VP9)
        }
#else
        if #available(iOS 26.2, tvOS 26.2, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        }
#endif
    }

    public func createRenderers(
        queue: Queue,
        clock: SEClock,
        renderSynchronizer: any PlaybackSynchronizer,
        textOutput: TextOutput,
        videoListener: VideoRendererEventListener,
        audioListener: AudioRendererEventListener
    ) -> [any SERenderer] {
        let audio = try? AVFAudioRenderer(
            queue: queue,
            clock: clock,
            renderSynchronizer: renderSynchronizer,
            eventListener: audioListener
        )
        let video = try? AVFVideoRenderer(queue: queue, clock: clock, eventListener: videoListener)
        return [audio, video, TextRenderer(queue: queue, clock: clock, output: textOutput)].compactMap { $0 }
    }
}
