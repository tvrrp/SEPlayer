//
//  AdPlaybackState.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.11.2025.
//

import CoreMedia

public struct AdPlaybackState: Hashable, Sendable {
    public static let none = AdPlaybackState(
        contentDuration: .invalid
    )

    private(set) public var contentDuration: CMTime

    init(adGroupTimes: [CMTime]) {
        contentDuration = .invalid
    }

    init(contentDuration: CMTime) {
        self.contentDuration = contentDuration
    }

    func withContentDuration(_ contentDuration: CMTime) -> Self {
        var copy = self
        copy.contentDuration = contentDuration
        return self
    }
}
