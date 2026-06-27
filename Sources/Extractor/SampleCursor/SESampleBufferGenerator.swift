//
//  SESampleBufferGenerator.swift
//  SEPlayer
//
//  Created by tvrrp on 22.06.2026.
//

import CoreMedia

public protocol SESampleBufferGenerator: Sendable {
    func makeSampleBuffer(for request: SESampleBufferRequest, isolation: isolated any Actor) async throws -> sending CMSampleBuffer
}

public protocol SESampleBufferRequest {
    var startCursor: SESampleCursor { get }
    var direction: SESampleBufferRequestDirection { get set }
    var limitCursor: SESampleCursor? { get set }
    var preferredMinSampleCount: Int { get set }
    var maxSampleCount: Int { get set }
    var mode: SESampleBufferRequestMode { get set }
    var overrideTime: CMTime { get set }
}

public enum SESampleBufferRequestDirection {
    case forward
    case none
    case reverse
}

public enum SESampleBufferRequestMode {
    case immediate
    case scheduled
    case opportunistic
}
