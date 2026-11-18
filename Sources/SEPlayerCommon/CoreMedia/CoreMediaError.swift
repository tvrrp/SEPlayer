//
//  CoreMediaError.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import CoreMedia
import Foundation

/// A failure a CoreMedia object reported.
///
/// Each kind of object has its own error type, and its known failures are constants of that type, to match in `catch`
/// clauses. The errors bridge to `NSError` in the OSStatus domain with the code CoreMedia returned.
public protocol CoreMediaError: Error, Hashable, Sendable, CustomNSError, CustomStringConvertible {
    /// The status CoreMedia returned.
    var status: OSStatus { get }

    init(status: OSStatus)

    /// The names of the known failures, by status.
    static var names: [OSStatus: String] { get }
}

public extension CoreMediaError {
    static var errorDomain: String { NSOSStatusErrorDomain }
    var errorCode: Int { Int(status) }

    var description: String {
        "\(Self.self).\(Self.names[status] ?? "unknown")(\(status))"
    }
}

/// A failure of a `CMBlockBuffer`.
public struct BlockBufferError: CoreMediaError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public static let structureAllocationFailed = Self(status: kCMBlockBufferStructureAllocationFailedErr)
    public static let blockAllocationFailed = Self(status: kCMBlockBufferBlockAllocationFailedErr)
    public static let badCustomBlockSource = Self(status: kCMBlockBufferBadCustomBlockSourceErr)
    public static let badOffsetParameter = Self(status: kCMBlockBufferBadOffsetParameterErr)
    public static let badLengthParameter = Self(status: kCMBlockBufferBadLengthParameterErr)
    public static let badPointerParameter = Self(status: kCMBlockBufferBadPointerParameterErr)
    public static let emptyBlockBuffer = Self(status: kCMBlockBufferEmptyBBufErr)
    public static let unallocatedBlock = Self(status: kCMBlockBufferUnallocatedBlockErr)
    public static let insufficientSpace = Self(status: kCMBlockBufferInsufficientSpaceErr)

    public static let names: [OSStatus: String] = [
        kCMBlockBufferStructureAllocationFailedErr: "structureAllocationFailed",
        kCMBlockBufferBlockAllocationFailedErr: "blockAllocationFailed",
        kCMBlockBufferBadCustomBlockSourceErr: "badCustomBlockSource",
        kCMBlockBufferBadOffsetParameterErr: "badOffsetParameter",
        kCMBlockBufferBadLengthParameterErr: "badLengthParameter",
        kCMBlockBufferBadPointerParameterErr: "badPointerParameter",
        kCMBlockBufferEmptyBBufErr: "emptyBlockBuffer",
        kCMBlockBufferUnallocatedBlockErr: "unallocatedBlock",
        kCMBlockBufferInsufficientSpaceErr: "insufficientSpace",
    ]
}

/// A failure of a `CMSampleBuffer`.
public struct SampleBufferError: CoreMediaError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public static let allocationFailed = Self(status: kCMSampleBufferError_AllocationFailed)
    public static let requiredParameterMissing = Self(status: kCMSampleBufferError_RequiredParameterMissing)
    public static let alreadyHasDataBuffer = Self(status: kCMSampleBufferError_AlreadyHasDataBuffer)
    public static let bufferNotReady = Self(status: kCMSampleBufferError_BufferNotReady)
    public static let sampleIndexOutOfRange = Self(status: kCMSampleBufferError_SampleIndexOutOfRange)
    public static let bufferHasNoSampleSizes = Self(status: kCMSampleBufferError_BufferHasNoSampleSizes)
    public static let bufferHasNoSampleTimingInfo = Self(status: kCMSampleBufferError_BufferHasNoSampleTimingInfo)
    public static let arrayTooSmall = Self(status: kCMSampleBufferError_ArrayTooSmall)
    public static let invalidEntryCount = Self(status: kCMSampleBufferError_InvalidEntryCount)
    public static let cannotSubdivide = Self(status: kCMSampleBufferError_CannotSubdivide)
    public static let sampleTimingInfoInvalid = Self(status: kCMSampleBufferError_SampleTimingInfoInvalid)
    public static let invalidMediaTypeForOperation = Self(status: kCMSampleBufferError_InvalidMediaTypeForOperation)
    public static let invalidSampleData = Self(status: kCMSampleBufferError_InvalidSampleData)
    public static let invalidMediaFormat = Self(status: kCMSampleBufferError_InvalidMediaFormat)
    public static let invalidated = Self(status: kCMSampleBufferError_Invalidated)
    public static let dataFailed = Self(status: kCMSampleBufferError_DataFailed)
    public static let dataCanceled = Self(status: kCMSampleBufferError_DataCanceled)

    public static let names: [OSStatus: String] = [
        kCMSampleBufferError_AllocationFailed: "allocationFailed",
        kCMSampleBufferError_RequiredParameterMissing: "requiredParameterMissing",
        kCMSampleBufferError_AlreadyHasDataBuffer: "alreadyHasDataBuffer",
        kCMSampleBufferError_BufferNotReady: "bufferNotReady",
        kCMSampleBufferError_SampleIndexOutOfRange: "sampleIndexOutOfRange",
        kCMSampleBufferError_BufferHasNoSampleSizes: "bufferHasNoSampleSizes",
        kCMSampleBufferError_BufferHasNoSampleTimingInfo: "bufferHasNoSampleTimingInfo",
        kCMSampleBufferError_ArrayTooSmall: "arrayTooSmall",
        kCMSampleBufferError_InvalidEntryCount: "invalidEntryCount",
        kCMSampleBufferError_CannotSubdivide: "cannotSubdivide",
        kCMSampleBufferError_SampleTimingInfoInvalid: "sampleTimingInfoInvalid",
        kCMSampleBufferError_InvalidMediaTypeForOperation: "invalidMediaTypeForOperation",
        kCMSampleBufferError_InvalidSampleData: "invalidSampleData",
        kCMSampleBufferError_InvalidMediaFormat: "invalidMediaFormat",
        kCMSampleBufferError_Invalidated: "invalidated",
        kCMSampleBufferError_DataFailed: "dataFailed",
        kCMSampleBufferError_DataCanceled: "dataCanceled",
    ]
}

/// A failure of a `CMFormatDescription`.
public struct FormatDescriptionError: CoreMediaError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public static let invalidParameter = Self(status: kCMFormatDescriptionError_InvalidParameter)
    public static let allocationFailed = Self(status: kCMFormatDescriptionError_AllocationFailed)
    public static let valueNotAvailable = Self(status: kCMFormatDescriptionError_ValueNotAvailable)
    /// A sample description that can't be read.
    public static let invalidSerializedSampleDescription = Self(status: kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription)
    public static let unsupportedSampleDescriptionFlavor = Self(status: kCMFormatDescriptionBridgeError_UnsupportedSampleDescriptionFlavor)

    public static let names: [OSStatus: String] = [
        kCMFormatDescriptionError_InvalidParameter: "invalidParameter",
        kCMFormatDescriptionError_AllocationFailed: "allocationFailed",
        kCMFormatDescriptionError_ValueNotAvailable: "valueNotAvailable",
        kCMFormatDescriptionBridgeError_InvalidParameter: "bridgeInvalidParameter",
        kCMFormatDescriptionBridgeError_AllocationFailed: "bridgeAllocationFailed",
        kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription: "invalidSerializedSampleDescription",
        kCMFormatDescriptionBridgeError_InvalidFormatDescription: "invalidFormatDescription",
        kCMFormatDescriptionBridgeError_IncompatibleFormatDescription: "incompatibleFormatDescription",
        kCMFormatDescriptionBridgeError_UnsupportedSampleDescriptionFlavor: "unsupportedSampleDescriptionFlavor",
        kCMFormatDescriptionBridgeError_InvalidSlice: "invalidSlice",
    ]
}

/// A failure of a `CMBufferQueue`.
public struct BufferQueueError: CoreMediaError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public static let allocationFailed = Self(status: kCMBufferQueueError_AllocationFailed)
    public static let requiredParameterMissing = Self(status: kCMBufferQueueError_RequiredParameterMissing)
    public static let invalidCMBufferCallbacksStruct = Self(status: kCMBufferQueueError_InvalidCMBufferCallbacksStruct)
    public static let enqueueAfterEndOfData = Self(status: kCMBufferQueueError_EnqueueAfterEndOfData)
    public static let queueIsFull = Self(status: kCMBufferQueueError_QueueIsFull)
    public static let badTriggerDuration = Self(status: kCMBufferQueueError_BadTriggerDuration)
    public static let cannotModifyQueueFromTriggerCallback = Self(status: kCMBufferQueueError_CannotModifyQueueFromTriggerCallback)
    public static let invalidTriggerCondition = Self(status: kCMBufferQueueError_InvalidTriggerCondition)
    public static let invalidTriggerToken = Self(status: kCMBufferQueueError_InvalidTriggerToken)
    public static let invalidBuffer = Self(status: kCMBufferQueueError_InvalidBuffer)

    public static let names: [OSStatus: String] = [
        kCMBufferQueueError_AllocationFailed: "allocationFailed",
        kCMBufferQueueError_RequiredParameterMissing: "requiredParameterMissing",
        kCMBufferQueueError_InvalidCMBufferCallbacksStruct: "invalidCMBufferCallbacksStruct",
        kCMBufferQueueError_EnqueueAfterEndOfData: "enqueueAfterEndOfData",
        kCMBufferQueueError_QueueIsFull: "queueIsFull",
        kCMBufferQueueError_BadTriggerDuration: "badTriggerDuration",
        kCMBufferQueueError_CannotModifyQueueFromTriggerCallback: "cannotModifyQueueFromTriggerCallback",
        kCMBufferQueueError_InvalidTriggerCondition: "invalidTriggerCondition",
        kCMBufferQueueError_InvalidTriggerToken: "invalidTriggerToken",
        kCMBufferQueueError_InvalidBuffer: "invalidBuffer",
    ]
}

/// A failure of a `CMClock`.
public struct ClockError: CoreMediaError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public static let missingRequiredParameter = Self(status: kCMClockError_MissingRequiredParameter)
    public static let invalidParameter = Self(status: kCMClockError_InvalidParameter)
    public static let allocationFailed = Self(status: kCMClockError_AllocationFailed)
    public static let unsupportedOperation = Self(status: kCMClockError_UnsupportedOperation)

    public static let names: [OSStatus: String] = [
        kCMClockError_MissingRequiredParameter: "missingRequiredParameter",
        kCMClockError_InvalidParameter: "invalidParameter",
        kCMClockError_AllocationFailed: "allocationFailed",
        kCMClockError_UnsupportedOperation: "unsupportedOperation",
    ]
}

/// A failure of a `CMTimebase`.
public struct TimebaseError: CoreMediaError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public static let missingRequiredParameter = Self(status: kCMTimebaseError_MissingRequiredParameter)
    public static let invalidParameter = Self(status: kCMTimebaseError_InvalidParameter)
    public static let allocationFailed = Self(status: kCMTimebaseError_AllocationFailed)
    public static let timerIntervalTooShort = Self(status: kCMTimebaseError_TimerIntervalTooShort)
    public static let readOnly = Self(status: kCMTimebaseError_ReadOnly)

    public static let names: [OSStatus: String] = [
        kCMTimebaseError_MissingRequiredParameter: "missingRequiredParameter",
        kCMTimebaseError_InvalidParameter: "invalidParameter",
        kCMTimebaseError_AllocationFailed: "allocationFailed",
        kCMTimebaseError_TimerIntervalTooShort: "timerIntervalTooShort",
        kCMTimebaseError_ReadOnly: "readOnly",
    ]
}

/// A failure of relating clocks and timebases to each other.
public struct SyncError: CoreMediaError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public static let missingRequiredParameter = Self(status: kCMSyncError_MissingRequiredParameter)
    public static let invalidParameter = Self(status: kCMSyncError_InvalidParameter)
    public static let allocationFailed = Self(status: kCMSyncError_AllocationFailed)
    public static let rateMustBeNonZero = Self(status: kCMSyncError_RateMustBeNonZero)

    public static let names: [OSStatus: String] = [
        kCMSyncError_MissingRequiredParameter: "missingRequiredParameter",
        kCMSyncError_InvalidParameter: "invalidParameter",
        kCMSyncError_AllocationFailed: "allocationFailed",
        kCMSyncError_RateMustBeNonZero: "rateMustBeNonZero",
    ]
}
