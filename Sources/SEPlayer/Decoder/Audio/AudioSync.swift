//
//  AudioSync.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AudioToolbox
import CoreMedia

protocol IAudioSync {
    func start() throws
    func hasPendingData() -> Bool
    func getPosition() -> Int64
    func enqueueImmediately(_ buffer: CMSampleBuffer) -> Bool
}

final class AudioSync2 {
    var audioQueue: AudioQueueRef!
    private var timeline: AudioQueueTimelineRef?
    private var outputFormat: AudioStreamBasicDescription
    private let bufferSize: UInt32

    private let outputQueue: TypedCMBufferQueue<CMSampleBuffer>
    private let queue: Queue
    private let outputSampleRate: Float64

    private var state: State = .idle
    private var writtenFrames: Int64 = 0

    private var audioQueueBuffers: [AudioQueueBufferRef] = []
    private var packetDescriptions: [AudioStreamPacketDescription]
    private var buffersInUse: [Bool]

    private var filledBufferIndex: Int = 0
    private var bytesFilled: Int64 = 0
    private var packetsFilled: Int = 0
    
    private var enquedBuffers: Int = 0

    private let internalQueue = Queues.audioQueue
    private let startCondition = NSCondition()

    private var mediaPositionParameters = MediaPositionParameters()
    private var mediaPositionParametersCheckpoints: [MediaPositionParameters] = []

    init(
        queue: Queue,
        clock: CMClock,
        outputQueue: TypedCMBufferQueue<CMSampleBuffer>,
        outputFormat: AudioStreamBasicDescription,
        outputSampleRate: Double
    ) throws {
        self.queue = queue
        self.outputQueue = outputQueue
        self.outputFormat = outputFormat
        self.outputSampleRate = outputSampleRate

        bufferSize = UInt32(outputFormat.mBytesPerPacket * outputFormat.mChannelsPerFrame * 1024)
        audioQueueBuffers.reserveCapacity(.maxBufferInUse)
        packetDescriptions = Array(repeating: AudioStreamPacketDescription(), count: .maxBufferInUse)
        buffersInUse = Array(repeating: false, count: .maxBufferInUse)

        try createAudioQueue()
    }

    deinit {
        audioQueueBuffers.forEach { $0.deallocate() }
    }

    func start(with hostTime: Int64) throws {
        guard let audioQueue else { return }

        try internalQueue.sync {
            let status = AudioQueueStart(audioQueue, nil)

            if status != noErr {
                throw AudioQueueErrors.osStatus(.init(rawValue: status), status)
            }
        }
        if state == .idle {
            startCondition.wait()
        }
        state = .started
    }

    func pause() throws {
        guard let audioQueue else { return }

        try internalQueue.sync {
            let status = AudioQueuePause(audioQueue)

            if status != noErr {
                throw AudioQueueErrors.osStatus(.init(rawValue: status), status)
            }
        }

        state = .paused
    }

    func cleanup() {
        guard let audioQueue else { return }

        if state == .started {
            let userData = Unmanaged.passUnretained(self).toOpaque()
            AudioQueueRemovePropertyListener(
                audioQueue,
                kAudioQueueProperty_IsRunning,
                audioQueuePropertyCallback,
                userData
            )

            AudioQueueStop(audioQueue, true)
            state = .idle
        }

        AudioQueueDispose(audioQueue, true)
        filledBufferIndex = 0
        bytesFilled = 0
        packetsFilled = 0
        buffersInUse = buffersInUse.map { _ in false }
    }

    func getPosition(sourceEnded: Bool) -> Int64 {
        var position = audioQueueTime()
        max(position, (Double(getWrittenFrames()) / outputSampleRate).microsecondsPerSecond)
        return applyMediaPositionParameters(position: position)
    }

    private func applyMediaPositionParameters(position: Int64) -> Int64 {
        while let first = mediaPositionParametersCheckpoints.first, position >= first.audioQueuePosition {
            mediaPositionParameters = mediaPositionParametersCheckpoints.removeFirst()
        }

        let playoutDurationSinceLastCheckpoint = position - mediaPositionParameters.audioQueuePosition
        let estimatedMediaDurationSinceLastCheckpoint = AudioUtils.mediaDurationFor(
            playoutDuration: playoutDurationSinceLastCheckpoint,
            speed: mediaPositionParameters.playbackSpeed
        )

        if mediaPositionParametersCheckpoints.isEmpty {
            let currentMediaPosition = mediaPositionParameters.mediaTime + playoutDurationSinceLastCheckpoint
            mediaPositionParameters.mediaPositionDrift = playoutDurationSinceLastCheckpoint - estimatedMediaDurationSinceLastCheckpoint
            return currentMediaPosition
        } else {
            return mediaPositionParameters.mediaTime + estimatedMediaDurationSinceLastCheckpoint + mediaPositionParameters.mediaPositionDrift
        }
    }

    func hasPendingData() -> Bool {
        let currentPosition = audioQueueTime()
        return getWrittenFrames() > AudioUtils.durationToSampleCount(
            duration: currentPosition,
            sampleRate: Int(outputSampleRate)
        )
    }

    func audioQueueTime() -> Int64 {
        guard let audioQueue else { return 0 }
        var audioTimeStamp = AudioTimeStamp()
        AudioQueueGetCurrentTime(audioQueue, nil, &audioTimeStamp, nil)
        return (audioTimeStamp.mSampleTime / outputSampleRate).microsecondsPerSecond
    }

    private func getWrittenFrames() -> Int64 {
        let bytesPerPacket = Int64(outputFormat.mBytesPerPacket)
        return (writtenFrames + bytesPerPacket - 1) / bytesPerPacket
    }

    func setPlaybackRate(new playbackRate: Float) throws {
        guard let audioQueue else { return }
        let rateStatus = AudioQueueSetParameter(audioQueue, kAudioQueueParam_PlayRate, playbackRate)

        if rateStatus != noErr {
            throw AudioQueueErrors.osStatus(.init(rawValue: rateStatus), rateStatus)
        }
    }

    func enqueueImmediately(_ buffer: CMSampleBuffer) -> Bool {
        guard buffersInUse.contains(false) else {
            return false
        }

        try! buffer.withUnsafeAudioStreamPacketDescriptions { packetDesriptions in
            try buffer.withAudioBufferList { audioBufferListPointer, _ in
                let data = audioBufferListPointer.unsafeMutablePointer.pointee.mBuffers.mData!
                let packetDescription = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: 0,
                    mDataByteSize: audioBufferListPointer.unsafeMutablePointer.pointee.mBuffers.mDataByteSize
                )
                let packetSize = packetDescription.mDataByteSize
                let buffer = audioQueueBuffers[filledBufferIndex]
                memcpy(buffer.pointee.mAudioData, data, Int(packetSize))

                self.packetDescriptions[packetsFilled] = packetDescription
                self.packetDescriptions[packetsFilled].mStartOffset = bytesFilled
                bytesFilled += Int64(packetSize)
                packetsFilled += 1

                enqueueBuffer()
            }
        }
        writtenFrames += Int64(buffer.numSamples)
        return true
    }

    private func enqueueBuffer() {
        assert(buffersInUse[filledBufferIndex] == false)
        buffersInUse[filledBufferIndex] = true

        let fillBuffer = audioQueueBuffers[filledBufferIndex]
        fillBuffer.pointee.mAudioDataByteSize = UInt32(bytesFilled)

        let status = AudioQueueEnqueueBuffer(audioQueue!, fillBuffer, UInt32(packetsFilled), &packetDescriptions[0])

        if status != noErr {
            let error = AudioQueueErrors.osStatus(.init(rawValue: status), status)
            fatalError("\(error)")
        }

        enquedBuffers += 1
        filledBufferIndex += 1

        if filledBufferIndex >= .maxBufferInUse {
            filledBufferIndex = 0
        }
        bytesFilled = 0
        packetsFilled = 0
    }
}

private extension AudioSync2 {
    private func createAudioQueue() throws {
        let createStatus = AudioQueueNewOutputWithDispatchQueue(
            &audioQueue, &outputFormat, 0, internalQueue.queue
        ) { [weak self] audioQueue, audioBuffer in
            self?.audioQueueDidRelease(audioQueue, buffer: audioBuffer)
        }

        if createStatus != noErr {
            throw AudioQueueErrors.osStatus(.init(rawValue: createStatus), createStatus)
        }

        guard let audioQueue else { throw AudioQueueErrors.unknown }

        for _ in 0..<Int.maxBufferInUse {
            var audioBuffer: AudioQueueBufferRef!
            let status = AudioQueueAllocateBuffer(audioQueue, bufferSize, &audioBuffer)

            if status != noErr {
                AudioQueueDispose(audioQueue, true)
                throw AudioQueueErrors.osStatus(.init(rawValue: createStatus), createStatus)
            }
            audioQueueBuffers.append(audioBuffer)
        }
        
        var enableTimePitchConversion: UInt32 = 1

        let timePitchStatus = AudioQueueSetProperty(
            audioQueue,
            kAudioQueueProperty_EnableTimePitch,
            &enableTimePitchConversion,
            UInt32(MemoryLayout.size(ofValue: enableTimePitchConversion))
        )

        if timePitchStatus != noErr {
            throw AudioQueueErrors.osStatus(.init(rawValue: timePitchStatus), timePitchStatus)
        }

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let propertyStatus = AudioQueueAddPropertyListener(
            audioQueue,
            kAudioQueueProperty_IsRunning,
            audioQueuePropertyCallback,
            userData
        )

        if propertyStatus != noErr {
            throw AudioQueueErrors.osStatus(.init(rawValue: propertyStatus), propertyStatus)
        }
        
        let timelineStatus = AudioQueueCreateTimeline(audioQueue, &timeline)

        if timelineStatus != noErr {
            throw AudioQueueErrors.osStatus(.init(rawValue: propertyStatus), propertyStatus)
        }
    }

    private func audioQueueDidRelease(_ audioQueue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        queue.async { [self] in
            var bufferIndex: Int? = nil

            for index in 0..<Int.maxBufferInUse {
                if buffer == audioQueueBuffers[index] {
                    bufferIndex = index
                    break
                }
            }

            guard let bufferIndex else { return }

            buffersInUse[bufferIndex] = false
        }
    }

    func handleAudioQueuePropertyCallback(propertyId: AudioQueuePropertyID) {
        switch propertyId {
        case kAudioQueueProperty_IsRunning:
            startCondition.signal()
        default:
            return
        }
    }
}

extension AudioSync2 {
    enum AudioQueueErrors: Error {
        case osStatus(Error?, OSStatus)
        case unknown

        enum Error: OSStatus {
            case InvalidBuffer = -66687
            case BufferEmpty = -66686
            case DisposalPending = -66685
            case InvalidProperty = -66684
            case InvalidPropertySize = -66683
            case InvalidParameter = -66682
            case CannotStart = -66681
            case InvalidDevice = -66680
            case BufferInQueue = -66679
            case InvalidRunState = -66678
            case InvalidQueueType = -66677
            case Permissions = -66676
            case InvalidPropertyValue = -66675
            case PrimeTimedOut = -66674
            case CodecNotFound = -66673
            case InvalidCodecAccess = -66672
            case QueueInvalidated = -66671
            case TooManyTaps = -66670
            case InvalidTapContext = -66669
            case RecordUnderrun = -66668
            case InvalidTapType = -66667
            case BufferEnqueuedTwice = -66666
            case CannotStartYet = -66665
            case EnqueueDuringReset = -66632
            case InvalidOfflineMode = -66626
        }
    }

    enum State {
        case idle
        case started
        case paused
        case stopped
        case flushed
    }

    struct MediaPositionParameters {
//        let playbackParameters: Float64
        let playbackSpeed: Float
        let mediaTime: Int64
        let audioQueuePosition: Int64
        var mediaPositionDrift: Int64 = 0

        init(playbackSpeed: Float = 1.0, mediaTime: Int64 = 1_000_000_000_000, audioQueuePosition: Int64 = 0) {
            self.playbackSpeed = playbackSpeed
            self.mediaTime = mediaTime
            self.audioQueuePosition = audioQueuePosition
        }
    }
}

private extension Int {
    static let maxBufferInUse: Int = 10
}

private func audioQueuePropertyCallback(_ userData: UnsafeMutableRawPointer?, audioQueue: AudioQueueRef, propertyId: AudioQueuePropertyID) {
    guard let userData else { return }
    let audioSync = Unmanaged<AudioSync2>.fromOpaque(userData).takeUnretainedValue()
    audioSync.handleAudioQueuePropertyCallback(propertyId: propertyId)
}
