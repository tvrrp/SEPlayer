//
//  SampleFlags.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

struct SampleFlags: OptionSet {
    let rawValue: UInt8
    static let keyframe = SampleFlags(rawValue: 1)
    static let endOfStream = SampleFlags(rawValue: 1 << 1)
    static let notDependedOn = SampleFlags(rawValue: 1 << 2)
    static let firstSample = SampleFlags(rawValue: 1 << 3)
    static let lastSample = SampleFlags(rawValue: 1 << 4)
}
