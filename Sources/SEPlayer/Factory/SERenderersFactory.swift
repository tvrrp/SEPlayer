//
//  SERenderersFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

protocol RenderersFactory {
    func createRenderers(dependencies: SEPlayerStateDependencies) -> [SERenderer]
}

struct DefaultRenderersFactory: RenderersFactory {
    private let decoderFactory: SEDecoderFactory

    init(decoderFactory: SEDecoderFactory) {
        self.decoderFactory = decoderFactory
    }

    func createRenderers(dependencies: SEPlayerStateDependencies) -> [any SERenderer] {
        let renderers = [
            try? CAVideoRenderer<VideoToolboxDecoder>(
                queue: dependencies.queue,
                clock: dependencies.clock,
                displayLink: dependencies.displayLink,
                bufferableContainer: dependencies.bufferableContainer,
                decoderFactory: decoderFactory
            ),
            try? AudioQueueRenderer<AudioConverterDecoder>(
                queue: dependencies.queue,
                clock: dependencies.clock,
                decoderFactory: decoderFactory
            )
        ].compactMap { $0 }

        return renderers
    }
}
