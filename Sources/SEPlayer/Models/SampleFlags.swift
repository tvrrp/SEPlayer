//
//  SampleFlags.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public struct SampleFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let keyframe = SampleFlags(rawValue: 1)
    public static let endOfStream = SampleFlags(rawValue: 1 << 1)
    public static let notDependedOn = SampleFlags(rawValue: 1 << 2)
    public static let firstSample = SampleFlags(rawValue: 1 << 3)
    public static let lastSample = SampleFlags(rawValue: 1 << 4)
}
