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
    func createRenderers(
        queue: Queue,
        clock: SEClock,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) -> [any SERenderer]
}

struct DefaultRenderersFactory: RenderersFactory {
    init() {
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

    func createRenderers(
        queue: Queue,
        clock: SEClock,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) -> [any SERenderer] {
        let renderers = [
            try? AVFVideoRenderer(
                queue: queue,
                clock: clock,
                allowedJoiningTimeMs: .zero,
                maxDroppedFramesToNotify: .zero
            ),
            try? AVFAudioRenderer(
                queue: queue,
                renderSynchronizer: renderSynchronizer,
                clock: clock
            )
        ].compactMap { $0 }

        return renderers
    }
}
