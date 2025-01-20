//
//  DecoderReadSampleTask.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.01.2025.
//

import AVFoundation
import CoreMedia

final class DecoderReadSampleTask: SEPlayerTask {
    private let decoder: SEDecoder
    private let enqueueDecodedSample: Bool
    private let sampleReleaser: SampleReleaser
    private let readyCallback: (() -> Void)?

    init(
        decoder: SEDecoder,
        enqueueDecodedSample: Bool,
        sampleReleaser: SampleReleaser,
        readyCallback: (() -> Void)? = nil
    ) {
        self.decoder = decoder
        self.enqueueDecodedSample = enqueueDecodedSample
        self.sampleReleaser = sampleReleaser
        self.readyCallback = readyCallback
    }

    override func execute() {
        guard decoder.isReadyForMoreMediaData else { finish(); return }
        decoder.readSamples(enqueueDecodedSample: enqueueDecodedSample) { [weak self] in
            guard let self else { return }
            sampleReleaser.dequeueFirstSampleIfNeeded()
            if sampleReleaser.isReady {
                readyCallback?()
            }
        } completion: { [weak self] error in
            self?.finish(error: error)
        }
    }
}
