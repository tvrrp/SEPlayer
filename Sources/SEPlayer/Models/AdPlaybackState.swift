//
//  AdPlaybackState.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.11.2025.
//

public struct AdPlaybackState: Hashable {
    public static let none = AdPlaybackState(
        contentDurationUs: .timeUnset
    )

    private(set) var contentDurationUs: Int64

    init(adGroupTimesUs: [Int64]) {
        contentDurationUs = .timeUnset
    }

    init(contentDurationUs: Int64) {
        self.contentDurationUs = contentDurationUs
    }

    func withContentDurationUs(_ contentDurationUs: Int64) -> Self {
        var copy = self
        copy.contentDurationUs = contentDurationUs
        return self
    }
}
