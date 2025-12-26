//
//  FakeRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

import CoreMedia
import Testing
@testable import SEPlayer

class FakeRenderer: BaseSERenderer {
//    var isInitialized = false
    var _isEnded = false
    var isReleased = false
    var positionResetCount = 0
    var sampleBufferReadCount = 0
    var enabledCount = 0
    var resetCount = 0

    private let sourceReadahedUs: Int64 = 250_000
    private let buffer: DecoderInputBuffer

    private var playbackPositionUs = Int64.zero
    private var lastSamplePositionUs: Int64
    private var hasPendingBuffer = false
    private(set) var formatsRead = [Format]()

    override init(queue: Queue = playerSyncQueue, trackType: TrackType, clock: SEClock) {
        buffer = DecoderInputBuffer()
        buffer.enqueue(buffer: UnsafeMutableRawBufferPointer(
            UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 1024 * 32)
        ))
        lastSamplePositionUs = .min
        super.init(queue: queue, trackType: trackType, clock: clock)
    }

    deinit {
        if let buffer = try? buffer.dequeue() {
            buffer.deallocate()
        }
    }

    override func onPositionReset(position: Int64, joining: Bool) throws {
        if playbackPositionUs == position && lastSamplePositionUs == .min && !_isEnded {
            // Nothing change, ignore reset operation.
            return
        }

        playbackPositionUs = position
        lastSamplePositionUs = .min
        hasPendingBuffer = false
        positionResetCount += 1
        _isEnded = false
    }

    override func render(position: Int64, elapsedRealtime: Int64) throws {
        guard !_isEnded else { return }

        playbackPositionUs = position
        while true {
            if !hasPendingBuffer {
                resetBuffer()
                let result = try readSource(to: buffer)
                print("🌈 RENDERER READ RESULT = \(result)")
                switch result {
                case let .didReadFormat(format):
                    guard format.sampleMimeType?.trackType == trackType else {
                        throw ErrorBuilder(errorDescription: "wrong track type") // TODO: real error
                    }
                    formatsRead.append(format)
                    onFormatChange(format: format)
                case .didReadBuffer:
                    if buffer.flags.contains(.endOfStream) {
                        print("🏙️ is ended")
                        _isEnded = true
                        return
                    }
                    hasPendingBuffer = true
                case .nothingRead:
                    nrCount += 1
                    return
                }
            } else {
                guard try shouldProcessBuffer(bufferTimeUs: buffer.time, playbackPositionUs: position) else {
                    return
                }

                print("🏙️ render fake buffer. time = \(buffer.time)")
                lastSamplePositionUs = buffer.time
                sampleBufferReadCount += 1
                hasPendingBuffer = false
            }
        }
    }

    private var nrCount = 0

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        enabledCount += 1
    }

    override func onReset() {
        resetCount += 1
    }

    override func isReady() -> Bool {
        lastSamplePositionUs >= playbackPositionUs || hasPendingBuffer || isSourceReady()
    }

    override func isEnded () -> Bool { _isEnded }

    override func getCapabilities() -> RendererCapabilities { self }

    func onFormatChange(format: Format) {}

    func shouldProcessBuffer(bufferTimeUs: Int64, playbackPositionUs: Int64) throws -> Bool {
        bufferTimeUs < playbackPositionUs + sourceReadahedUs
    }

    override func onRelease() {
        isReleased = true
    }

    private func resetBuffer() {
        if let buffer = try? buffer.dequeue() {
            buffer.deallocate()
        }
        buffer.reset()

        buffer.enqueue(buffer: UnsafeMutableRawBufferPointer(
            UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 1024 * 32)
        ))
    }
}

extension FakeRenderer: RendererCapabilities {
    func supportsFormat(_ format: Format) -> Bool {
        return format.sampleMimeType?.trackType == trackType
    }
}
