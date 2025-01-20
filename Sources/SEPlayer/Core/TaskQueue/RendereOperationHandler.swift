//
//  RendereOperationHandler.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.01.2025.
//

import AVFoundation

final class RendereOperationHandler {
    var isReady: Bool = false

    private let queue: Queue
    private let format: CMFormatDescription
    private let timebase: CMTimebase
    private let sampleQueue: TypedCMBufferQueue<CMSampleBuffer>
    private let decoder: SEDecoder
    private let renderer: AVQueuedSampleBufferRendering
    private let timer: DispatchSourceTimer

    init(
        queue: Queue,
        format: CMFormatDescription,
        timebase: CMTimebase,
        sampleQueue: TypedCMBufferQueue<CMSampleBuffer>,
        decoder: SEDecoder,
        renderer: AVQueuedSampleBufferRendering
    ) throws {
        self.queue = queue
        self.format = format
        self.sampleQueue = sampleQueue
        self.decoder = decoder
        self.timebase = timebase
        self.renderer = renderer
        self.timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue.queue)

        try setupTimer()
    }

    func doSomeJob(nextDeadline: CMTime) {
        if decoder.isReadyForMoreMediaData {
            decoder.readSamples(enqueueDecodedSample: true) { [weak self] in
                guard let self else { return }
            } completion: { [weak self] error in
                guard let self else { return }
                
            }
        }
    }
}

private extension RendereOperationHandler {
    func setupTimer() throws {
        timer.setEventHandler { [weak self] in
            
        }
        timer.activate()
        try timebase.addTimer(timer)
    }
}
