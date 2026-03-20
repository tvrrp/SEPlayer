//
//  PreloadConfiguration.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.05.2025.
//

import CoreMedia

public struct PreloadConfiguration: Equatable {
    let targetPreloadDuration: CMTime

    public static let `default` = PreloadConfiguration(targetPreloadDuration: .invalid)
}
