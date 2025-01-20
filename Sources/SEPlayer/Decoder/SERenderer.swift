//
//  SERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.01.2025.
//

import CoreMedia

protocol SERenderer {
    var trackType: TrackType { get }
    var state: SERendererState { get }
    var timebase: CMTimebase { get }
    var stream: SampleStream? { get }
    var streamDidEnd: Bool { get }
    var readingPosition: CMTime { get }
    var isReady: Bool { get }
    var isEnded: Bool { get }

    func onSleep()
    func onWakeup()

    func enable(
        formats: [CMFormatDescription],
        stream: SampleStream,
        position: CMTime,
        mayRenderStartOfStream: Bool,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws

    func replaceStream(
        formats: [CMFormatDescription],
        stream: SampleStream,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws

    func start() throws
    func resetPosition(new time: CMTime) throws
    func setPlaybackSpeed(current: Float, target: Float) throws
    func setTimeline(_ timeline: Timeline)
    func render(position: CMTime) throws
    func stop()
    func disable()
    func reset()
    func release()
}

extension SERenderer {
    func durationToProgress(position: CMTime, elapsedRealtime: CMTime) -> CMTime {
        return .zero
    }
}

enum SERendererState {
    case disabled
    case enabled
    case started
}

//class SEBaseRenderer: SERenderer {
//    var trackType: TrackType = .unknown
//    var state: SERendererState = .disabled
//    let timebase: CMTimebase
//    var streamDidEnd: Bool { false }
//    var readingPosition: CMTime = .negativeInfinity
//
//    var isReady: Bool {
//        false
//    }
//
//    var isEnded: Bool {
//        false
//    }
//
//    var stream: SampleStream?
//
//    private let queue: Queue
//    private let index: Int
//    private let playerId: UUID
//
//    private var isStreamFinal: Bool = false
//
//    init(queue: Queue, index: Int, playerId: UUID, timebase: CMTimebase) {
//        self.queue = queue
//        self.timebase = timebase
//    }
//
//    func enable(
//        formats: [CMFormatDescription],
//        stream: SampleStream,
//        position: CMTime,
//        mayRenderStartOfStream: Bool,
//        startPosition: CMTime,
//        offset: CMTime,
//        mediaPeriodId: MediaPeriodId
//    ) throws {
//        guard state == .disabled else { throw RenderError.wrongState }
//        state = .enabled
//        onEnabled(mayRenderStartOfStream: mayRenderStartOfStream)
//        try replaceStream(formats: formats, stream: stream, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
//        try resetPosition(new: startPosition)
//    }
//
//    func start() throws {
//        guard state == .enabled else { throw RenderError.wrongState }
//        state = .started
//        try onStarted()
//    }
//
//    func replaceStream(
//        formats: [CMFormatDescription],
//        stream: SampleStream,
//        startPosition: CMTime,
//        offset: CMTime,
//        mediaPeriodId: MediaPeriodId
//    ) throws {
//        guard !isStreamFinal else { throw RenderError.wrongState }
//        self.stream = stream
//        
//    }
//
//    final func resetPosition(new time: CMTime) throws {
////        streamDidEnd
//        
//    }
//
//    func onEnabled(mayRenderStartOfStream: Bool) {
//        // Do nothing.
//    }
//
//    func onStreamChanged(
//        formats: [CMFormatDescription],
//        startPosition: CMTime,
//        offset: CMTime,
//        mediaPeriodId: MediaPeriodId
//    ) throws {
//        // Do nothing.
//    }
//
//    func onPositionReset(new time: CMTime) throws {
//        // Do nothing.
//    }
//
//    func onStarted() throws {
//        // Do nothing.
//    }
//
//    func onStopped() throws {
//        // Do nothing.
//    }
//
//    func onDisabled() throws {
//        
//    }
//
//    func onReset() throws {
//        
//    }
//}
//
//extension SEBaseRenderer {
//    enum RenderError: Error {
//        case wrongState
//    }
//}
