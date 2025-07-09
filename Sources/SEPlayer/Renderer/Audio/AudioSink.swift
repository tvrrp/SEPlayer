//
//  AudioSync.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AudioToolbox
import CoreMedia

protocol AudioSinkDelegate: AnyObject {
    func onPositionDiscontinuity()
}

protocol IAudioSink: AnyObject {
    var delegate: AudioSinkDelegate? { get set }
    func getPosition() -> Int64?
    func configure(inputFormat: AudioStreamBasicDescription, channelLayout: ManagedAudioChannelLayout?) throws
    func play()
    func pause()
    func handleDiscontinuity()
    func handleBuffer(_ buffer: CMSampleBuffer, presentationTime: Int64) throws -> Bool
    func playToEndOfStream() throws
    func isEnded() -> Bool
    func hasPendingData() -> Bool
    func setPlaybackParameters(new playbackParameters: PlaybackParameters)
    func getPlaybackParameters() -> PlaybackParameters
//    func flush()
    func flush(reuse: Bool)
    func reset()
}

final class AudioSink: IAudioSink {
    weak var delegate: AudioSinkDelegate?

    private var pendingConfiguration: Configuration?
    private var configuration: Configuration!
    private var playbackParameters = PlaybackParameters.default

    private var audioQueue: AudioQueueRef?
    private let audioQueuePositionTracker: AudioQueuePositionTracker
    private var bufferSize: UInt32 = 0

    private var isPlaying = false
    private var didStartAudioQueue = false
    private var isAudioQueueStopped = true
    private var didHandleEndOfStream = false

    private let queue: Queue
    private let clock: CMClock

    private var submitedFrames: Int64 = 0
    private var writtenFrames: Int64 = 0

    private var inputBuffer: AudioSampleByfferWrapper?
    private var outputBuffer: AudioSampleByfferWrapper?

    private var audioQueueBuffers: [AudioQueueBufferRef] = []
    private var buffersInUse: [Bool]
    private var filledBufferIndex: Int = 0

    private let internalQueue = Queues.audioQueue
//    private let startCondition = NSCondition()

    private var startMediaTimeNeedsInit = false
    private var startMediaTimeNeedsSync = false
    private var startMediaTime: Int64 = .zero

    private var mediaPositionParameters = MediaPositionParameters()
    private var mediaPositionParametersCheckpoints: [MediaPositionParameters] = []

    init(queue: Queue, clock: CMClock) {
        self.queue = queue
        self.clock = clock
        self.audioQueuePositionTracker = AudioQueuePositionTracker(clock: clock)

        audioQueueBuffers.reserveCapacity(.maxBufferInUse)
        buffersInUse = Array(repeating: false, count: .maxBufferInUse)
    }

    func getPosition() -> Int64? {
        guard audioQueue != nil, !startMediaTimeNeedsInit else {
            return nil
        }

        let position = audioQueuePositionTracker.getCurrentPosition()
        return applyMediaPositionParameters(position: position)
    }

    func configure(
        inputFormat: AudioStreamBasicDescription,
        channelLayout: ManagedAudioChannelLayout?
    ) throws {
        let pendingConfiguration = Configuration(outputFormat: inputFormat, channelLayout: channelLayout)
        if audioQueue != nil {
            self.pendingConfiguration = pendingConfiguration
        } else {
            configuration = pendingConfiguration
        }
    }

    func play() {
        guard let audioQueue else { return }
        audioQueuePositionTracker.start()
        if !isPlaying {
            internalQueue.async {
                AudioQueueStart(audioQueue, nil)
            }
        }
        if !didStartAudioQueue {
//            startCondition.wait()
            didStartAudioQueue = true
        }
        isPlaying = true
    }

    func handleDiscontinuity() {
        startMediaTimeNeedsSync = true
    }

    func handleBuffer(_ buffer: CMSampleBuffer, presentationTime: Int64) throws -> Bool {
        assert(inputBuffer == nil || inputBuffer?.has(same: buffer) == true)

        if let pendingConfiguration {
            if try! !drainToEndOfStream() {
                return false
            } else if let configuration, !pendingConfiguration.canReuseAudioQueue(new: configuration) {
                playPendingData()
                if hasPendingData() {
                    return false
                }
                flush(reuse: true)
            } else {
                configuration = pendingConfiguration
                self.pendingConfiguration = nil
            }
            applyPlaybackParameters(presentationTime: presentationTime)
        }

        if audioQueue == nil {
            try! initializeAudioQueue()
        }

        if startMediaTimeNeedsInit {
            startMediaTime = max(0, presentationTime)
            startMediaTimeNeedsInit = false
            startMediaTimeNeedsSync = false

            setPlaybackParameters()
            applyPlaybackParameters(presentationTime: presentationTime)

            if isPlaying {
                play()
            }
        }

        if inputBuffer == nil {
            guard let configuration else { return false }
            let expectedPresentationTime = startMediaTime + configuration.framesToDuration(frameCount: getSubmittedFrames())
            if !startMediaTimeNeedsSync && abs(expectedPresentationTime - presentationTime) > 200_000 {
                startMediaTimeNeedsSync = true
            }

            if startMediaTimeNeedsSync {
                guard try! drainToEndOfStream() else { return false }
                let adjustmentTime = presentationTime - expectedPresentationTime
                startMediaTime += adjustmentTime
                startMediaTimeNeedsSync = false
                applyPlaybackParameters(presentationTime: presentationTime)
                if adjustmentTime != 0 {
                    delegate?.onPositionDiscontinuity()
                }
            }
            submitedFrames += Int64(buffer.numSamples)
            inputBuffer = try! AudioSampleByfferWrapper(sample: buffer)
        }

        try! processBuffers()

        if inputBuffer?.hasRemaining() == false {
            inputBuffer = nil
            return true
        }

        if audioQueuePositionTracker.isStalled(writtenFrames: getWrittenFrames()) {
            flush(reuse: false)
            return true
        }

        return false
    }

    private func initializeAudioQueue() throws {
        try! createAudioQueue()
        startMediaTimeNeedsInit = true
    }

    private func processBuffers() throws {
        try! drainOutputBuffer()
        guard outputBuffer == nil, let inputBuffer else { return }

        outputBuffer = inputBuffer
        try! drainOutputBuffer()
    }

    private func drainToEndOfStream() throws -> Bool {
        try! drainOutputBuffer()
        return outputBuffer == nil
    }

    private func drainOutputBuffer() throws {
        guard buffersInUse[filledBufferIndex] == false, let outputBuffer else { return }

        let bytesRemaining = try! outputBuffer.bytesRemaining()
        let bytesWrittenOrOSStatus = try! writeBytesToAudioBuffer(outputBuffer: outputBuffer)

        if bytesWrittenOrOSStatus < 0 {
            fatalError()
        }

        if configuration?.outputMode == .pcm {
            writtenFrames += bytesWrittenOrOSStatus
        }

        if bytesWrittenOrOSStatus == bytesRemaining {
            self.outputBuffer = nil
        }
    }

    func playToEndOfStream() throws {
        if !didHandleEndOfStream, audioQueue != nil, try! drainToEndOfStream() {
            playPendingData()
            didHandleEndOfStream = true
        }
    }

    func isEnded() -> Bool {
        return audioQueue == nil || (didHandleEndOfStream && !hasPendingData())
    }

    func hasPendingData() -> Bool {
        return audioQueue != nil && audioQueuePositionTracker.hasPendingData(writtenFrames: getWrittenFrames())
    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        self.playbackParameters = playbackParameters

        setPlaybackParameters()
    }

    func getPlaybackParameters() -> PlaybackParameters {
        return playbackParameters
    }

    func pause() {
        isPlaying = false
        if let audioQueue, audioQueuePositionTracker.pause() {
//            AudioQueuePause(audioQueue)
            pauseAudioQueue()
        }
    }

    private func pauseAudioQueue() {
        guard let audioQueue else { return }
//        AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, .zero)
        AudioQueuePause(audioQueue)
//        AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, 1.0)
    }

    func flush(reuse: Bool) {
        guard let audioQueue else { return }
//        AudioQueuePause(audioQueue)
        pauseAudioQueue()
        resetSinkStateForFlush()
        var reuse = reuse
        if let pendingConfiguration {
            reuse = reuse && configuration == pendingConfiguration
            configuration = pendingConfiguration
            self.pendingConfiguration = nil
        }
        audioQueuePositionTracker.reset()
        self.audioQueue = nil
        didStartAudioQueue = false

        switch reuse {
        case true:
            let result = AudioQueueReset(audioQueue)
            if result != noErr { fallthrough }
        case false:
            releaseAudioQueue(audioQueue: audioQueue)
        }
    }

    func reset() {
        flush(reuse: false)
        isPlaying = false
    }

    private func resetSinkStateForFlush() {
        submitedFrames = 0
        writtenFrames = 0
        mediaPositionParameters = .init(playbackParameters: playbackParameters)
        startMediaTime = 0
        mediaPositionParametersCheckpoints.removeAll()
        inputBuffer = nil
        outputBuffer = nil
        isAudioQueueStopped = false
        didHandleEndOfStream = false
    }

    private func setPlaybackParameters() {
        guard let audioQueue else { return }

        AudioQueueSetParameter(audioQueue, kAudioQueueParam_PlayRate, playbackParameters.playbackRate)
//        AudioQueueSetParameter(audioQueue, kAudioQueueParam_Pitch, playbackParameters.pitch)
        audioQueuePositionTracker.setPlaybackSpeed(new: playbackParameters.playbackRate)
    }

    private func applyPlaybackParameters(presentationTime: Int64) {
        mediaPositionParametersCheckpoints.append(
            MediaPositionParameters(
                playbackParameters: playbackParameters,
                mediaTime: max(0, presentationTime),
                audioQueuePosition: configuration?.framesToDuration(frameCount: getWrittenFrames()) ?? 0
            )
        )
    }

    private func applyMediaPositionParameters(position: Int64) -> Int64 {
        while let first = mediaPositionParametersCheckpoints.first,
              position >= first.audioQueuePosition {
            mediaPositionParameters = mediaPositionParametersCheckpoints.removeFirst()
        }

        let playoutDurationSinceLastCheckpoint = position - mediaPositionParameters.audioQueuePosition
        let estimatedMediaDurationSinceLastCheckpoint = AudioUtils.mediaDurationFor(
            playoutDuration: playoutDurationSinceLastCheckpoint,
            speed: mediaPositionParameters.playbackParameters.playbackRate
        )

        if mediaPositionParametersCheckpoints.isEmpty {
            let currentMediaPosition = mediaPositionParameters.mediaTime + playoutDurationSinceLastCheckpoint
            mediaPositionParameters.mediaPositionDrift = playoutDurationSinceLastCheckpoint - estimatedMediaDurationSinceLastCheckpoint
            return currentMediaPosition
        } else {
            return mediaPositionParameters.mediaTime + estimatedMediaDurationSinceLastCheckpoint + mediaPositionParameters.mediaPositionDrift
        }
    }

    private func getSubmittedFrames() -> Int64 {
        let bytesPerPacket = Int64(configuration.outputFormat.mBytesPerPacket)
        return (submitedFrames + bytesPerPacket - 1) / bytesPerPacket
    }

    private func getWrittenFrames() -> Int64 {
        let bytesPerPacket = Int64(configuration.outputFormat.mBytesPerPacket)
        return (writtenFrames + bytesPerPacket - 1) / bytesPerPacket
    }

    private func writeBytesToAudioBuffer(outputBuffer: AudioSampleByfferWrapper) throws -> Int64 {
        assert(buffersInUse[filledBufferIndex] == false)
        var writtenFrames: Int64 = 0
        let audioQueueBuffer = audioQueueBuffers[filledBufferIndex]
        var availableSize = audioQueueBuffer.pointee.mAudioDataBytesCapacity

        while outputBuffer.hasRemaining() {
            let result = try! outputBuffer.nextBuffer { audioBuffer, audioPacketDescription in
                let packetSize = audioBuffer.mDataByteSize
                guard availableSize > packetSize else { return false }

                memcpy(audioQueueBuffer.pointee.mAudioData, audioBuffer.mData, Int(packetSize))
                audioQueueBuffer.pointee.mAudioDataByteSize = packetSize
                availableSize -= packetSize

                let status = AudioQueueEnqueueBuffer(audioQueue!, audioQueueBuffer, 0, nil)
                if status != noErr {
                    writtenFrames = Int64(status)
                    return false
                } else {
                    writtenFrames += Int64(packetSize)
                    return true
                }
            }
            if !result { break }
        }

        if writtenFrames > 0 {
            buffersInUse[filledBufferIndex] = true
            filledBufferIndex += 1

            if filledBufferIndex >= .maxBufferInUse {
                filledBufferIndex = 0
            }
        }

        return writtenFrames
    }

    private func playPendingData() {
        guard let audioQueue else { return }
        if !isAudioQueueStopped {
            isAudioQueueStopped = true
            audioQueuePositionTracker.handleEndOfStream(writtenFrames: getWrittenFrames())
            AudioQueueStop(audioQueue, false)
        }
    }

    private func releaseAudioQueue(audioQueue: AudioQueueRef) {
        filledBufferIndex = 0
        buffersInUse = buffersInUse.map { _ in false }

        internalQueue.async {
            let userData = Unmanaged.passUnretained(self).toOpaque()
            AudioQueueRemovePropertyListener(
                audioQueue,
                kAudioQueueProperty_IsRunning,
                audioQueuePropertyCallback,
                userData
            )
            AudioQueueFlush(audioQueue)
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
        }
    }
}

private extension AudioSink {
    private func createAudioQueue() throws {
        guard let configuration else { throw AudioQueueErrors.emptyConfiguration }
        var outputFormat = configuration.outputFormat

        let userData = Unmanaged.passUnretained(self).toOpaque()
        bufferSize = UInt32(outputFormat.mBytesPerPacket * outputFormat.mChannelsPerFrame * 1024)
        let createStatus = AudioQueueNewOutput(
            &outputFormat,
            audioQueueOutputCallback,
            userData,
            nil,
            nil,
            0,
            &audioQueue
        )

        if createStatus != noErr {
            throw AudioQueueErrors.osStatus(.init(rawValue: createStatus), createStatus)
        }

        guard let audioQueue else { throw AudioQueueErrors.unknown }

        audioQueueBuffers.removeAll(keepingCapacity: true)
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

        var timePitchAlgorithm = kAudioQueueTimePitchAlgorithm_TimeDomain
        let timePitchAlgorithmStatus = AudioQueueSetProperty(
            audioQueue,
            kAudioQueueProperty_TimePitchAlgorithm,
            &timePitchAlgorithm,
            UInt32(MemoryLayout.size(ofValue: timePitchAlgorithm))
        )

        if timePitchAlgorithmStatus != noErr {
            throw AudioQueueErrors.osStatus(.init(rawValue: timePitchAlgorithmStatus), timePitchAlgorithmStatus)
        }

        if var audioChannelLayout = configuration.channelLayout {
            let audioChanellStatus = try audioChannelLayout.withUnsafeMutablePointer { channelLayout in
                let size = UInt32(MemoryLayout.size(ofValue: channelLayout.pointee))
                return AudioQueueSetProperty(
                    audioQueue,
                    kAudioQueueProperty_ChannelLayout,
                    channelLayout,
                    size
                )
            }

            if audioChanellStatus != noErr {
                throw AudioQueueErrors.osStatus(.init(rawValue: audioChanellStatus), audioChanellStatus)
            }
        }

        let propertyStatus = AudioQueueAddPropertyListener(
            audioQueue,
            kAudioQueueProperty_IsRunning,
            audioQueuePropertyCallback,
            userData
        )

        if propertyStatus != noErr {
            throw AudioQueueErrors.osStatus(.init(rawValue: propertyStatus), propertyStatus)
        }

        audioQueuePositionTracker.setAudioQueue(
            audioQueue,
            outputFormat: outputFormat
        )
    }

    func audioQueueDidRelease(_ audioQueue: AudioQueueRef, buffer: AudioQueueBufferRef) {
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
            audioQueuePositionTracker.didReleaseAudioQueueBuffer()
        }
    }

    func handleAudioQueuePropertyCallback(propertyId: AudioQueuePropertyID) {
        switch propertyId {
        case kAudioQueueProperty_IsRunning:
             print("running")
//            startCondition.signal()
        default:
            return
        }
    }
}

extension AudioSink {
    enum AudioQueueErrors: Error {
        case osStatus(Error?, OSStatus)
        case emptyConfiguration
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
        let playbackParameters: PlaybackParameters
        let mediaTime: Int64
        let audioQueuePosition: Int64
        var mediaPositionDrift: Int64 = 0

        init(playbackParameters: PlaybackParameters = .default, mediaTime: Int64 = 1_000_000_000_000, audioQueuePosition: Int64 = 0) {
            self.playbackParameters = playbackParameters
            self.mediaTime = mediaTime
            self.audioQueuePosition = audioQueuePosition
        }
    }

    struct Configuration: Equatable {
        var outputFormat: AudioStreamBasicDescription
        var channelLayout: ManagedAudioChannelLayout?
        let outputMode: OutputMode
        let bufferSize: UInt32

        enum OutputMode {
            case pcm
            case passthrough
        }

        init(
            outputFormat: AudioStreamBasicDescription,
            channelLayout: ManagedAudioChannelLayout?,
            bufferSize: UInt32? = nil
        ) {
            self.outputFormat = outputFormat
            self.channelLayout = channelLayout
            self.outputMode = outputFormat.mFormatID == kAudioFormatLinearPCM ? .pcm : .passthrough
            self.bufferSize = bufferSize ?? UInt32(outputFormat.mBytesPerPacket * outputFormat.mChannelsPerFrame * 1024)
        }

        func canReuseAudioQueue(new configuration: Configuration) -> Bool {
            outputFormat == configuration.outputFormat
        }

        func framesToDuration(frameCount: Int64) -> Int64 {
            AudioUtils.sampleCountToDuration(sampleCount: frameCount, sampleRate: outputFormat.mSampleRate)
        }
    }
}

private extension Int {
    static let maxBufferInUse: Int = 10
}

private func audioQueueOutputCallback(_ userData: UnsafeMutableRawPointer?, audioQueue: AudioQueueRef, audioBuffer: AudioQueueBufferRef) {
    guard let userData else { return }
    let audioSync = Unmanaged<AudioSink>.fromOpaque(userData).takeUnretainedValue()
    audioSync.audioQueueDidRelease(audioQueue, buffer: audioBuffer)
}

private func audioQueuePropertyCallback(_ userData: UnsafeMutableRawPointer?, audioQueue: AudioQueueRef, propertyId: AudioQueuePropertyID) {
    guard let userData else { return }
    let audioSync = Unmanaged<AudioSink>.fromOpaque(userData).takeUnretainedValue()
    audioSync.handleAudioQueuePropertyCallback(propertyId: propertyId)
}

private final class AudioSampleByfferWrapper {
    private let isPCM: Bool
    private let sample: CMSampleBuffer
    private var maxBuffers: Int!

    private var audioPacketDescriptions: [AudioStreamPacketDescription]

    private var bufferIndex = 0

    init(sample: CMSampleBuffer) throws {
        self.sample = sample
        isPCM = sample.formatDescription?.audioStreamBasicDescription?.mFormatID == kAudioFormatLinearPCM
        self.audioPacketDescriptions = try! sample.audioStreamPacketDescriptions()

        try! sample.withAudioBufferList { audioBufferList, retainingBlockBuffer in
            self.maxBuffers = audioBufferList.count
        }
    }

    func nextBuffer(_ buffer: (UnsafeMutableAudioBufferListPointer.Element, AudioStreamPacketDescription?) -> Bool) throws -> Bool {
        guard bufferIndex < maxBuffers else { return false }
        return try! sample.withAudioBufferList { audioBufferList, _ in
            let audioBuffer = audioBufferList[bufferIndex]
            let audioPacketDescription: AudioStreamPacketDescription? = isPCM ? nil : audioPacketDescriptions[bufferIndex]

            if buffer(audioBuffer, audioPacketDescription) {
                bufferIndex += 1
                return true
            } else {
                return false
            }
        }
    }

    func hasRemaining() -> Bool {
        bufferIndex < maxBuffers
    }

    func bytesRemaining() throws -> Int64 {
        guard bufferIndex < maxBuffers else {
            return 0
        }
        return try! sample.withAudioBufferList { audioBufferList, _ in
            var bytes: Int64 = 0
            for buffer in audioBufferList[bufferIndex..<maxBuffers] {
                bytes += Int64(buffer.mDataByteSize)
            }
            return bytes
        }
    }

    func has(same buffer: CMSampleBuffer) -> Bool {
        self.sample === buffer
    }
}
