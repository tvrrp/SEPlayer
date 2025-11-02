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
        clock: CMClock,
        bufferableContainer: PlayerBufferableContainer,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) -> [any SERenderer]
}

struct DefaultRenderersFactory: RenderersFactory {
    private let decoderFactory: SEDecoderFactory

    init(decoderFactory: SEDecoderFactory) {
        self.decoderFactory = decoderFactory
    }

    func createRenderers(
        queue: Queue,
        clock: CMClock,
        bufferableContainer: PlayerBufferableContainer,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) -> [any SERenderer] {
        let renderers = [
            try? CAVideoRenderer<VideoToolboxDecoder>(
                queue: queue,
                clock: clock,
                bufferableContainer: bufferableContainer,
                decoderFactory: decoderFactory
            ),
            try? AudioQueueRenderer<AudioConverterDecoder>(
                queue: queue,
                clock: clock,
                renderSynchronizer: renderSynchronizer,
                decoderFactory: decoderFactory,
            ),
        ].compactMap { $0 }

        return renderers
    }
}
