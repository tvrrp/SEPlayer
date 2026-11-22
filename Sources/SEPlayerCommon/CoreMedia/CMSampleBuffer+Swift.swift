//
//  CMSampleBuffer+Swift.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import CoreAudioTypes
import CoreMedia
import CoreVideo

public extension _CoreMediaInitializable where Self == CMSampleBuffer {
    /// A sample buffer of `numSamples` samples in `dataBuffer`, ready to use.
    ///
    /// - Parameters:
    ///   - sampleTimings: One timing per sample, one for all of them, or none.
    ///   - sampleSizes: One size per sample, one for all of them, or none.
    init(
        dataBuffer: CMBlockBuffer?,
        formatDescription: CMFormatDescription?,
        numSamples: Int,
        sampleTimings: [CMSampleTimingInfo],
        sampleSizes: [Int]
    ) throws(SampleBufferError) {
        var buffer: CMSampleBuffer?
        let status = sampleTimings.withUnsafeBufferPointer { timings in
            sampleSizes.withUnsafeBufferPointer { sizes in
                CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: dataBuffer,
                    formatDescription: formatDescription,
                    sampleCount: numSamples,
                    sampleTimingEntryCount: timings.count,
                    sampleTimingArray: timings.baseAddress,
                    sampleSizeEntryCount: sizes.count,
                    sampleSizeArray: sizes.baseAddress,
                    sampleBufferOut: &buffer
                )
            }
        }
        guard status == noErr, let buffer else {
            throw SampleBufferError(status: status)
        }
        self = buffer
    }

    /// A sample buffer of compressed audio packets in `dataBuffer`, ready to use.
    init(
        dataBuffer: CMBlockBuffer?,
        formatDescription: CMFormatDescription,
        numSamples: Int,
        presentationTimeStamp: CMTime,
        packetDescriptions: [AudioStreamPacketDescription]
    ) throws(SampleBufferError) {
        guard let dataBuffer else { throw .requiredParameterMissing }
        var buffer: CMSampleBuffer?
        let status = packetDescriptions.withUnsafeBufferPointer { descriptions in
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: dataBuffer,
                formatDescription: formatDescription,
                sampleCount: numSamples,
                presentationTimeStamp: presentationTimeStamp,
                packetDescriptions: descriptions.isEmpty ? nil : descriptions.baseAddress,
                sampleBufferOut: &buffer
            )
        }
        guard status == noErr, let buffer else {
            throw SampleBufferError(status: status)
        }
        self = buffer
    }

    /// A sample buffer of one decoded image.
    init(imageBuffer: CVImageBuffer, formatDescription: CMVideoFormatDescription, sampleTiming: CMSampleTimingInfo) throws(SampleBufferError) {
        var buffer: CMSampleBuffer?
        let status = withUnsafePointer(to: sampleTiming) { timing in
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: formatDescription,
                sampleTiming: timing,
                sampleBufferOut: &buffer
            )
        }
        guard status == noErr, let buffer else {
            throw SampleBufferError(status: status)
        }
        self = buffer
    }

    /// A copy of `sampleBuffer` that shares its data and copies its attachments.
    init(copying sampleBuffer: CMSampleBuffer) throws(SampleBufferError) {
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else {
            throw SampleBufferError(status: status)
        }
        self = buffer
    }

    /// A copy of `sampleBuffer` with other timings.
    init(copying sampleBuffer: CMSampleBuffer, withNewTiming sampleTimings: [CMSampleTimingInfo]) throws(SampleBufferError) {
        var buffer: CMSampleBuffer?
        let status = sampleTimings.withUnsafeBufferPointer { timings in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: timings.count,
                sampleTimingArray: timings.baseAddress,
                sampleBufferOut: &buffer
            )
        }
        guard status == noErr, let buffer else {
            throw SampleBufferError(status: status)
        }
        self = buffer
    }
}

public extension CMSampleBuffer {
    /// Gives a sample buffer created without data its data.
    func setDataBuffer(to dataBuffer: CMBlockBuffer) throws(SampleBufferError) {
        let status = CMSampleBufferSetDataBuffer(self, newValue: dataBuffer)
        guard status == noErr else { throw SampleBufferError(status: status) }
    }

    // MARK: - Timing

    /// Sets when the samples show, after trimming and speed changes.
    func setOutputPresentationTimeStamp(to timeStamp: CMTime) throws(SampleBufferError) {
        let status = CMSampleBufferSetOutputPresentationTimeStamp(self, newValue: timeStamp)
        guard status == noErr else { throw SampleBufferError(status: status) }
    }

    /// The timings of the samples, one per sample or one for all of them.
    func sampleTimings() throws(SampleBufferError) -> [CMSampleTimingInfo] {
        try timingInfos { CMSampleBufferGetSampleTimingInfoArray(self, entryCount: $0, arrayToFill: $1, entriesNeededOut: $2) }
    }

    /// The timings of the samples, after trimming and speed changes.
    func outputSampleTimings() throws(SampleBufferError) -> [CMSampleTimingInfo] {
        try timingInfos { CMSampleBufferGetOutputSampleTimingInfoArray(self, entryCount: $0, arrayToFill: $1, entriesNeededOut: $2) }
    }

    /// The timing of the sample at `sampleIndex`.
    func sampleTiming(at sampleIndex: Int) throws(SampleBufferError) -> CMSampleTimingInfo {
        var timing = CMSampleTimingInfo()
        let status = CMSampleBufferGetSampleTimingInfo(self, at: sampleIndex, timingInfoOut: &timing)
        guard status == noErr else { throw SampleBufferError(status: status) }
        return timing
    }

    private func timingInfos(
        _ get: (Int, UnsafeMutablePointer<CMSampleTimingInfo>?, UnsafeMutablePointer<Int>?) -> OSStatus
    ) throws(SampleBufferError) -> [CMSampleTimingInfo] {
        var count = 0
        var status = get(0, nil, &count)
        guard status == noErr else { throw SampleBufferError(status: status) }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        status = timings.withUnsafeMutableBufferPointer { get(count, $0.baseAddress, nil) }
        guard status == noErr else { throw SampleBufferError(status: status) }
        return timings
    }

    // MARK: - Attachments

    /// The attachments of the buffer as a whole.
    var bufferAttachments: SampleBufferAttachments {
        SampleBufferAttachments(buffer: self)
    }

    /// The attachments of each sample.
    var perSampleAttachments: PerSampleAttachments {
        PerSampleAttachments(buffer: self)
    }

    /// Copies the attachments that propagate to `destination`.
    func propagateAttachments(to destination: CMSampleBuffer) {
        CMPropagateAttachments(self, destination: destination)
    }
}

/// The attachments of a sample buffer as a whole: instructions to its consumer, such as to drain a decoder or that
/// the media ended.
///
/// Values are Core Foundation values or ones that bridge to them, such as `Bool` and `[String: Any]`.
public struct SampleBufferAttachments: @unchecked Sendable {
    /// Whether an attachment goes on to buffers made from this one.
    public enum Mode: Sendable {
        case shouldPropagate
        case shouldNotPropagate

        init(_ mode: CMAttachmentMode) {
            self = mode == kCMAttachmentMode_ShouldNotPropagate ? .shouldNotPropagate : .shouldPropagate
        }

        var attachmentMode: CMAttachmentMode {
            switch self {
            case .shouldPropagate: kCMAttachmentMode_ShouldPropagate
            case .shouldNotPropagate: kCMAttachmentMode_ShouldNotPropagate
            }
        }
    }

    public struct Key: RawRepresentable, Hashable, @unchecked Sendable {
        public let rawValue: CFString

        public init(rawValue: CFString) {
            self.rawValue = rawValue
        }

        public static let resetDecoderBeforeDecoding = Self(rawValue: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding)
        public static let drainAfterDecoding = Self(rawValue: kCMSampleBufferAttachmentKey_DrainAfterDecoding)
        public static let postNotificationWhenConsumed = Self(rawValue: kCMSampleBufferAttachmentKey_PostNotificationWhenConsumed)
        public static let resumeOutput = Self(rawValue: kCMSampleBufferAttachmentKey_ResumeOutput)
        public static let transitionID = Self(rawValue: kCMSampleBufferAttachmentKey_TransitionID)
        public static let trimDurationAtStart = Self(rawValue: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        public static let trimDurationAtEnd = Self(rawValue: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        public static let speedMultiplier = Self(rawValue: kCMSampleBufferAttachmentKey_SpeedMultiplier)
        public static let reverse = Self(rawValue: kCMSampleBufferAttachmentKey_Reverse)
        public static let fillDiscontinuitiesWithSilence = Self(rawValue: kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence)
        public static let emptyMedia = Self(rawValue: kCMSampleBufferAttachmentKey_EmptyMedia)
        public static let permanentEmptyMedia = Self(rawValue: kCMSampleBufferAttachmentKey_PermanentEmptyMedia)
        public static let displayEmptyMediaImmediately = Self(rawValue: kCMSampleBufferAttachmentKey_DisplayEmptyMediaImmediately)
        public static let endsPreviousSampleDuration = Self(rawValue: kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration)
        public static let gradualDecoderRefresh = Self(rawValue: kCMSampleBufferAttachmentKey_GradualDecoderRefresh)
        public static let droppedFrameReason = Self(rawValue: kCMSampleBufferAttachmentKey_DroppedFrameReason)
        public static let forceKeyFrame = Self(rawValue: kCMSampleBufferAttachmentKey_ForceKeyFrame)
    }

    let buffer: CMSampleBuffer

    /// The value of `key`. Setting a value attaches it so that it propagates; setting `nil` removes it.
    public subscript(key: Key) -> Any? {
        get { CMGetAttachment(buffer, key: key.rawValue, attachmentModeOut: nil) }
        nonmutating set {
            if let newValue {
                set(newValue, for: key)
            } else {
                CMRemoveAttachment(buffer, key: key.rawValue)
            }
        }
    }

    /// The value of `key` as a Boolean, without bridging it to Swift; `nil` when there is none or it isn't one.
    public func bool(for key: Key) -> Bool? {
        cfBoolValue(CMGetAttachment(buffer, key: key.rawValue, attachmentModeOut: nil))
    }

    /// The value of `key` as a time, attached as a dictionary; `nil` when there is none or it isn't one.
    public func time(for key: Key) -> CMTime? {
        guard let dictionary = CMGetAttachment(buffer, key: key.rawValue, attachmentModeOut: nil) as? NSDictionary else {
            return nil
        }
        let time = CMTimeMakeFromDictionary(dictionary as CFDictionary)
        return time.isValid ? time : nil
    }

    /// Whether the attachment of `key` propagates, if there is one.
    public func mode(of key: Key) -> Mode? {
        var mode = CMAttachmentMode()
        guard CMGetAttachment(buffer, key: key.rawValue, attachmentModeOut: &mode) != nil else {
            return nil
        }
        return Mode(mode)
    }

    public func set(_ value: Any, for key: Key, mode: Mode = .shouldPropagate) {
        CMSetAttachment(buffer, key: key.rawValue, value: value as AnyObject, attachmentMode: mode.attachmentMode)
    }

    /// Attaches all of `attachments`, replacing the values of their keys.
    public func merge(_ attachments: [Key: Any], mode: Mode = .shouldPropagate) {
        for (key, value) in attachments {
            set(value, for: key, mode: mode)
        }
    }

    public func removeAll() {
        CMRemoveAllAttachments(buffer)
    }

    /// The attachments of one mode.
    public func all(_ mode: Mode) -> [Key: Any] {
        guard let dictionary = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault,
            target: buffer,
            attachmentMode: mode.attachmentMode
        ) as? [String: Any] else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: dictionary.map { (Key(rawValue: $0.key as CFString), $0.value) })
    }
}

/// The attachments of each sample of a sample buffer, such as whether it is a sync sample.
///
/// The samples have attachments once one is set; until then their values are `nil`.
public struct PerSampleAttachments: RandomAccessCollection, @unchecked Sendable {
    public struct Key: RawRepresentable, Hashable, @unchecked Sendable {
        public let rawValue: CFString

        public init(rawValue: CFString) {
            self.rawValue = rawValue
        }

        public static let notSync = Self(rawValue: kCMSampleAttachmentKey_NotSync)
        public static let partialSync = Self(rawValue: kCMSampleAttachmentKey_PartialSync)
        public static let hasRedundantCoding = Self(rawValue: kCMSampleAttachmentKey_HasRedundantCoding)
        public static let isDependedOnByOthers = Self(rawValue: kCMSampleAttachmentKey_IsDependedOnByOthers)
        public static let dependsOnOthers = Self(rawValue: kCMSampleAttachmentKey_DependsOnOthers)
        public static let earlierDisplayTimesAllowed = Self(rawValue: kCMSampleAttachmentKey_EarlierDisplayTimesAllowed)
        public static let displayImmediately = Self(rawValue: kCMSampleAttachmentKey_DisplayImmediately)
        public static let doNotDisplay = Self(rawValue: kCMSampleAttachmentKey_DoNotDisplay)
        public static let hevcTemporalLevelInfo = Self(rawValue: kCMSampleAttachmentKey_HEVCTemporalLevelInfo)
        public static let hevcSyncSampleNALUnitType = Self(rawValue: kCMSampleAttachmentKey_HEVCSyncSampleNALUnitType)
        public static let hevcTemporalSubLayerAccess = Self(rawValue: kCMSampleAttachmentKey_HEVCTemporalSubLayerAccess)
        public static let hevcStepwiseTemporalSubLayerAccess = Self(
            rawValue: kCMSampleAttachmentKey_HEVCStepwiseTemporalSubLayerAccess
        )
        public static let audioIndependentSampleDecoderRefreshCount = Self(
            rawValue: kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount
        )
    }

    /// The attachments of one sample.
    public struct Sample: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let index: Int

        /// The value of `key`; setting `nil` removes it.
        public subscript(key: Key) -> Any? {
            get {
                guard let dictionary = dictionary(creating: false),
                      let value = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key.rawValue).toOpaque()) else {
                    return nil
                }
                return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
            }
            nonmutating set {
                guard let dictionary = dictionary(creating: true) else {
                    return
                }
                let key = Unmanaged.passUnretained(key.rawValue).toOpaque()
                if let newValue {
                    CFDictionarySetValue(dictionary, key, Unmanaged.passUnretained(newValue as AnyObject).toOpaque())
                } else {
                    CFDictionaryRemoveValue(dictionary, key)
                }
            }
        }

        /// The value of `key` as a Boolean, without bridging it to Swift; `nil` when there is none or it isn't one.
        public func bool(for key: Key) -> Bool? {
            guard let dictionary = dictionary(creating: false),
                  let value = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key.rawValue).toOpaque()) else {
                return nil
            }
            return cfBoolValue(Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue())
        }

        /// All attachments of the sample.
        public var all: [Key: Any] {
            guard let dictionary = dictionary(creating: false) as? [String: Any] else {
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: dictionary.map { (Key(rawValue: $0.key as CFString), $0.value) })
        }

        /// The sample's dictionary in the buffer's array, made with the array when `creating`.
        private func dictionary(creating: Bool) -> CFMutableDictionary? {
            guard let array = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: creating),
                  index >= 0, index < CFArrayGetCount(array) else {
                return nil
            }
            return unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: CFMutableDictionary.self)
        }
    }

    let buffer: CMSampleBuffer

    public var startIndex: Int { 0 }
    public var endIndex: Int { CMSampleBufferGetNumSamples(buffer) }

    /// The attachments of the sample at `position`. Setting replaces them with those of another sample.
    public subscript(position: Int) -> Sample {
        get { Sample(buffer: buffer, index: position) }
        nonmutating set {
            let sample = Sample(buffer: buffer, index: position)
            let replacements = newValue.all
            for key in sample.all.keys where replacements[key] == nil {
                sample[key] = nil
            }
            for (key, value) in replacements {
                sample[key] = value
            }
        }
    }
}

/// A Core Foundation Boolean, or a number of 0 or 1, as a `Bool`: what `as? Bool` gives, without a dynamic cast.
private func cfBoolValue(_ value: CFTypeRef?) -> Bool? {
    guard let value else { return nil }
    if value === kCFBooleanTrue { return true }
    if value === kCFBooleanFalse { return false }

    let typeID = CFGetTypeID(value)
    if typeID == CFBooleanGetTypeID() {
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
    guard typeID == CFNumberGetTypeID() else { return nil }
    var number: Int64 = 0
    guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &number) else {
        return nil
    }
    switch number {
    case 0: return false
    case 1: return true
    default: return nil
    }
}
