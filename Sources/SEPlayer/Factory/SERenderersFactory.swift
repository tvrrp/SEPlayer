//
//  SERenderersFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

import CoreMedia.CMSync

protocol RenderersFactory {
    func createRenderers(
        queue: Queue,
        clock: CMClock,
        displayLink: DisplayLinkProvider,
        bufferableContainer: PlayerBufferableContainer
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
        displayLink: DisplayLinkProvider,
        bufferableContainer: PlayerBufferableContainer
    ) -> [any SERenderer] {
        let renderers = [
            try? CAVideoRenderer<VideoToolboxDecoder>(
                queue: queue,
                clock: clock,
                displayLink: displayLink,
                bufferableContainer: bufferableContainer,
                decoderFactory: decoderFactory
            ),
            try? AudioQueueRenderer<AudioConverterDecoder>(
                queue: queue,
                clock: clock,
                decoderFactory: decoderFactory
            )
        ].compactMap { $0 }

        return renderers
    }
}
