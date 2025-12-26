//
//  SEPlayerView.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AVFoundation
import UIKit

public protocol SEPlayerViewDelegate: AnyObject {
    func willRenderNewBuffer(_ view: SEPlayerView, of size: CGSize)
}

public final class SEPlayerView: UIView {
    public override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    @MainActor public weak var delegate: SEPlayerViewDelegate?

    @MainActor public weak var player: Player? {
        get {
            assert(Queues.mainQueue.isCurrent())
            return _player
        }
        set {
            assert(Queues.mainQueue.isCurrent())
            _set(player: newValue)
        }
    }

    @MainActor public var gravity: AVLayerVideoGravity {
        get { displayLayer.videoGravity }
        set { displayLayer.videoGravity = newValue }
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private var erasedSampleBufferRenderer: Any?
    @available(iOS 17.0, *)
    private var sampleBufferRenderer: AVSampleBufferVideoRenderer {
        erasedSampleBufferRenderer as! AVSampleBufferVideoRenderer
    }

    private weak var _player: Player?
    private var currentFormat: Format?

    private var oldIsReadyForMoreMediaData: Bool = true
    private let lock = UnfairLock()

    public init() {
        super.init(frame: .zero)
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true

        if #available(iOS 17.0, *) {
            erasedSampleBufferRenderer = displayLayer.sampleBufferRenderer
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError()
    }
}

extension SEPlayerView: PlayerBufferable {
    public var isReadyForMoreMediaData: Bool {
        if #available(iOS 17, *) {
            sampleBufferRenderer.isReadyForMoreMediaData
        } else {
            lock.withLock { oldIsReadyForMoreMediaData }
        }
    }

    public func requestMediaDataWhenReady(on queue: Queue, block: @escaping () -> Void) {
        if #available(iOS 17.0, *) {
            sampleBufferRenderer.requestMediaDataWhenReady(on: queue.queue, using: block)
        } else {
            DispatchQueue.main.async { [self] in
                displayLayer.requestMediaDataWhenReady(on: queue.queue) {
                    lock.withLock { self.oldIsReadyForMoreMediaData = true }
                    block()
                }
            }
        }
    }

    public func stopRequestingMediaData() {
        if #available(iOS 17.0, *) {
            sampleBufferRenderer.stopRequestingMediaData()
        } else {
            DispatchQueue.main.async {
                self.displayLayer.stopRequestingMediaData()
            }
        }
    }

    public func setControlTimebase(_ timebase: CMTimebase?) {
        DispatchQueue.main.async {
            self.displayLayer.controlTimebase = timebase
        }
    }

    public func prepare(for action: PlayerBufferableAction) {
        if action == .reset {
            if #available(iOS 17, *) {
                sampleBufferRenderer.flush(removingDisplayedImage: true)
            } else {
                DispatchQueue.main.async {
                    self.displayLayer.flushAndRemoveImage()
                }

                lock.withLock { self.oldIsReadyForMoreMediaData = true }
            }
        }
    }

    public func enqueue(_ buffer: CMSampleBuffer, format: Format?) {
        if #available(iOS 17, *) {
            sampleBufferRenderer.enqueue(buffer)
        } else {
            DispatchQueue.main.async { [self] in
                displayLayer.enqueue(buffer)
                let isReadyForMoreMediaData = displayLayer.isReadyForMoreMediaData
                lock.withLock { oldIsReadyForMoreMediaData = isReadyForMoreMediaData }

                if !isReadyForMoreMediaData {
                    displayLayer.requestMediaDataWhenReady(on: .main) {
                        displayLayer.stopRequestingMediaData()
                        lock.withLock { oldIsReadyForMoreMediaData = true }
                    }
                }
            }
        }

        DispatchQueue.main.async { [self] in
            if let pixelBuffer = buffer.imageBuffer {
                delegate?.willRenderNewBuffer(self, of: CGSize(
                    width:  CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                ))
            }

            if let format, currentFormat != format {
                currentFormat = format

                displayLayer.transform = format.transform3D
            }
        }
    }

    public func end() {
        if #available(iOS 17, *) {
            sampleBufferRenderer.flush(removingDisplayedImage: false)
        } else {
            DispatchQueue.main.async {
                self.displayLayer.flush()
            }

            lock.withLock { self.oldIsReadyForMoreMediaData = true }
        }
    }
}

private extension SEPlayerView {
    @MainActor
    func _set(player: Player?) {
        _player?.remove(self)

        player?.register(self)
        _player = player
    }
}
