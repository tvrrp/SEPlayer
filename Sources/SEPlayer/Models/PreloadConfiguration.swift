//
//  PreloadConfiguration.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.05.2025.
//

public struct PreloadConfiguration: Equatable {
    let targetPreloadDurationUs: Int64

    public static let `default` = PreloadConfiguration(targetPreloadDurationUs: .timeUnset)
}
