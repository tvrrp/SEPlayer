//
//  SERenderersFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//
//  Portions of this file are derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.RenderersFactory
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import AVFoundation
import Extractor
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
        metadataOutput: MetadataOutput,
        videoListener: VideoRendererEventListener,
        audioListener: AudioRendererEventListener
    ) -> [any SERenderer]
}

public extension RenderersFactory {
    func makeSynchronizer() -> any PlaybackSynchronizer { AVSampleBufferRenderSynchronizer() }
}

/// Makes renderers on AVFoundation's sample buffer renderers: `AVSampleBufferAudioRenderer` and
/// `AVSampleBufferDisplayLayer`, in an `AVSampleBufferRenderSynchronizer`.
///
/// The renderers give the samples of the formats the system plays to AVFoundation as they are, and decode the others
/// with decoders of the decoder factories. To change one renderer, make the others with this factory: drop the
/// renderer of its track type from what it makes, and add your own.
public struct DefaultRenderersFactory: RenderersFactory {
    private let videoDecoderFactory: VideoDecoderFactory?
    private let audioDecoderFactory: AudioDecoderFactory?
    private let metadataDecoderFactory: MetadataDecoderFactory

    /// - Parameters:
    ///   - videoDecoderFactory: Makes the video decoders of the formats the system doesn't play.
    ///   - audioDecoderFactory: Makes the audio decoders of the formats the system doesn't play.
    ///   - metadataDecoderFactory: Makes the decoders of the metadata renderer.
    public init(
        videoDecoderFactory: VideoDecoderFactory? = nil,
        audioDecoderFactory: AudioDecoderFactory? = nil,
        metadataDecoderFactory: MetadataDecoderFactory = DefaultMetadataDecoderFactory()
    ) {
        self.videoDecoderFactory = videoDecoderFactory
        self.audioDecoderFactory = audioDecoderFactory
        self.metadataDecoderFactory = metadataDecoderFactory
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
        metadataOutput: MetadataOutput,
        videoListener: VideoRendererEventListener,
        audioListener: AudioRendererEventListener
    ) -> [any SERenderer] {
        let audio = try? AVFAudioRenderer(
            queue: queue,
            clock: clock,
            renderSynchronizer: renderSynchronizer,
            eventListener: audioListener,
            decoderFactory: audioDecoderFactory
        )
        let video = try? AVFVideoRenderer(
            queue: queue,
            clock: clock,
            eventListener: videoListener,
            decoderFactory: videoDecoderFactory
        )
        return [
            audio,
            video,
            TextRenderer(queue: queue, clock: clock, output: textOutput),
            MetadataRenderer(queue: queue, clock: clock, output: metadataOutput, decoderFactory: metadataDecoderFactory),
        ].compactMap { $0 }
    }
}
