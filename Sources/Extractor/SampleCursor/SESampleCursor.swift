//
//  SESampleCursor.swift
//  SEPlayer
//
//  Created by tvrrp on 22.06.2026.
//

import CoreMedia
import SEPlayerCommon

public protocol SESampleCursor: AnyObject, Sendable {
    var presentationTimeStamp: CMTime { get }
    var decodeTimeStamp: CMTime { get }
    var currentSampleDuration: CMTime { get }

    var currentSampleSyncInfo: SESampleCursorSyncInfo { get }
    var currentSampleDependencyInfo: SESampleCursorDependencyInfo { get }
    var currentSampleDependencyAttachments: [AnyHashable : Any]? { get }
    var currentSampleAudioDependencyInfo: SESampleCursorAudioDependencyInfo { get }
    var samplesRequiredForDecoderRefresh: Int { get }

    var currentChunkStorageURL: URL? { get }
    var currentChunkStorageRange: Range<Int> { get }
    var currentChunkInfo: SESampleCursorChunkInfo { get }
    var currentSampleIndexInChunk: Int64 { get }
    var currentSampleStorageRange: Range<Int> { get }

    func stepInDecodeOrder(byCount stepCount: Int64) -> Int
    func stepInPresentationOrder(byCount stepCount: Int64) -> Int64
    func step(byDecodeTime deltaDecodeTime: CMTime) -> (CMTime, wasPinned: Bool)
    func step(byPresentationTime deltaPresentationTime: CMTime) -> (CMTime, wasPinned: Bool)

    func comparePositionInDecodeOrder(withPositionOf cursor: any SESampleCursor) -> ComparisonResult
    func maySamplesWithEarlierDecodeTimeStampsHavePresentationTimeStamps(laterThan cursor: any SESampleCursor) -> Bool
    func maySamplesWithLaterDecodeTimeStampsHavePresentationTimeStamps(earlierThan cursor: any SESampleCursor) -> Bool

    func copyCurrentSampleFormatDescription() -> Format
}

public struct SESampleCursorSyncInfo {
    public let sampleIsFullSync: Bool
    public let sampleIsPartialSync: Bool
    public let sampleIsDroppable: Bool

    public init(
        sampleIsFullSync: Bool,
        sampleIsPartialSync: Bool,
        sampleIsDroppable: Bool
    ) {
        self.sampleIsFullSync = sampleIsFullSync
        self.sampleIsPartialSync = sampleIsPartialSync
        self.sampleIsDroppable = sampleIsDroppable
    }
}

public struct SESampleCursorDependencyInfo {
    public let sampleIndicatesWhetherItHasDependentSamples: Bool
    public let sampleHasDependentSamples: Bool
    public let sampleIndicatesWhetherItDependsOnOthers: Bool
    public let sampleDependsOnOthers: Bool
    public let sampleIndicatesWhetherItHasRedundantCoding: Bool
    public let sampleHasRedundantCoding: Bool

    public init(
        sampleIndicatesWhetherItHasDependentSamples: Bool,
        sampleHasDependentSamples: Bool,
        sampleIndicatesWhetherItDependsOnOthers: Bool,
        sampleDependsOnOthers: Bool,
        sampleIndicatesWhetherItHasRedundantCoding: Bool,
        sampleHasRedundantCoding: Bool
    ) {
        self.sampleIndicatesWhetherItHasDependentSamples = sampleIndicatesWhetherItHasDependentSamples
        self.sampleHasDependentSamples = sampleHasDependentSamples
        self.sampleIndicatesWhetherItDependsOnOthers = sampleIndicatesWhetherItDependsOnOthers
        self.sampleDependsOnOthers = sampleDependsOnOthers
        self.sampleIndicatesWhetherItHasRedundantCoding = sampleIndicatesWhetherItHasRedundantCoding
        self.sampleHasRedundantCoding = sampleHasRedundantCoding
    }
}

public struct SESampleCursorAudioDependencyInfo {
    public let audioSampleIsIndependentlyDecodable: Bool
    public let audioSamplePacketRefreshCount: Int

    init(audioSampleIsIndependentlyDecodable: Bool, audioSamplePacketRefreshCount: Int) {
        self.audioSampleIsIndependentlyDecodable = audioSampleIsIndependentlyDecodable
        self.audioSamplePacketRefreshCount = audioSamplePacketRefreshCount
    }
}

public struct SESampleCursorChunkInfo {
    public let chunkSampleCount: Int64
    public let chunkHasUniformSampleSizes: Bool
    public let chunkHasUniformSampleDurations: Bool
    public let chunkHasUniformFormatDescriptions: Bool

    public init(
        chunkSampleCount: Int64,
        chunkHasUniformSampleSizes: Bool,
        chunkHasUniformSampleDurations: Bool,
        chunkHasUniformFormatDescriptions: Bool
    ) {
        self.chunkSampleCount = chunkSampleCount
        self.chunkHasUniformSampleSizes = chunkHasUniformSampleSizes
        self.chunkHasUniformSampleDurations = chunkHasUniformSampleDurations
        self.chunkHasUniformFormatDescriptions = chunkHasUniformFormatDescriptions
    }
}
