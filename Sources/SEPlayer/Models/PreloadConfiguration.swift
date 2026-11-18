//
//  PreloadConfiguration.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.05.2025.
//

import CoreMedia

public struct PreloadConfiguration: Equatable {
    /// How much of the next item to load ahead; `.invalid` doesn't preload.
    public let targetPreloadDuration: CMTime

    public init(targetPreloadDuration: CMTime) {
        self.targetPreloadDuration = targetPreloadDuration
    }

    public static let `default` = PreloadConfiguration(targetPreloadDuration: .invalid)
}
