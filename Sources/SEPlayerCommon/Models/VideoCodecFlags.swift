//
//  VideoCodecFlags.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

public struct VideoCodecFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let h264 = VideoCodecFlags(rawValue: 1)
    public static let h265 = VideoCodecFlags(rawValue: 2)
}
