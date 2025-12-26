//
//  DecoderVideoRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.12.2025.
//

class DecoderVideoRenderer<VideoDecoder: Decoder>: BaseSERenderer {
    private var inputFormat: Format?
    private var outputFormat: Format?

    private var decoder: VideoDecoder?

    override func render(position: Int64, elapsedRealtime: Int64) throws {
        
    }

    override func isEnded() -> Bool {
        fatalError()
    }

    override func isReady() -> Bool {
        fatalError()
    }

    override func handleMessage(_ message: RendererMessage) throws {
        if case let .setVideoOutput(output) = message {
            
        } else if case let .removeVideoOutput(output) = message {
            
        } else {
            try super.handleMessage(message)
        }
    }

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        
    }

    override func enableRenderStartOfStream() {
        
    }

    override func onPositionReset(position: Int64, joining: Bool) throws {
        
    }

    override func onStarted() throws {
        
    }

    override func onStopped() {
        
    }

    override func onDisabled() {
        
    }

    override func onStreamChanged(formats: [Format], startPosition: Int64, offset: Int64, mediaPeriodId: MediaPeriodId) throws {
        
    }

    func flushDecoder() throws {
        
    }

    func releaseDecoder() {
        
    }

    func onQueueInputBuffer() throws {
        
    }

    func createDecoder() -> VideoDecoder {
        fatalError()
    }
}

extension DecoderVideoRenderer {
    enum ReinitializationState {
        case none
        case signalEndOfStream
        case waitEndOfStream
    }
}
