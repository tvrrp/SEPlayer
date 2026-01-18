//
//  SERenderersFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

import AVFoundation

public protocol RenderersFactory {
    func createRenderers(
        queue: Queue,
        clock: SEClock,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) -> [any SERenderer]
}

struct DefaultRenderersFactory: RenderersFactory {
    func createRenderers(
        queue: Queue,
        clock: SEClock,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) -> [any SERenderer] {
        let renderers = [
            AVFVideoRenderer(
                queue: queue,
                clock: clock,
                allowedJoiningTimeMs: .zero,
                maxDroppedFramesToNotify: .zero
            ),
            AVFAudioRenderer(
                queue: queue,
                renderSynchronizer: renderSynchronizer,
                clock: clock
            )
        ].compactMap { $0 }

        return renderers
    }
}
