//
//  Period.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

import CoreMedia

public final class Period {
    public var id: AnyHashable?
    public var uid: AnyHashable?
    public var windowIndex: Int = .zero
    public var duration: CMTime = .zero
    public var positionInWindow: CMTime = .zero
    public var isPlaceholder: Bool = false
    public var adPlaybackState: AdPlaybackState

    public init() {
        adPlaybackState = .none
    }

    @discardableResult
    public func set(
        id: AnyHashable?,
        uid: AnyHashable?,
        windowIndex: Int,
        duration: CMTime,
        positionInWindow: CMTime,
        adPlaybackState: AdPlaybackState = .none,
        isPlaceholder: Bool = false,
    ) -> Period {
        self.id = id
        self.uid = uid
        self.windowIndex = windowIndex
        self.duration = duration
        self.positionInWindow = positionInWindow
        self.adPlaybackState = adPlaybackState
        self.isPlaceholder = isPlaceholder
        return self
    }

    public init(
        id: AnyHashable? = nil,
        uid: AnyHashable? = nil,
        windowIndex: Int = .zero,
        duration: CMTime = .zero,
        positionInWindow: CMTime = .zero,
        isPlaceholder: Bool = false,
        adPlaybackState: AdPlaybackState = .none
    ) {
        self.id = id
        self.uid = uid
        self.windowIndex = windowIndex
        self.duration = duration
        self.positionInWindow = positionInWindow
        self.isPlaceholder = isPlaceholder
        self.adPlaybackState = adPlaybackState
    }
}

extension Period: Hashable {
    public static func == (lhs: Period, rhs: Period) -> Bool {
        guard lhs !== rhs else { return true }

        return lhs.id == rhs.id
            && lhs.uid == rhs.uid
            && lhs.windowIndex == rhs.windowIndex
            && lhs.duration == rhs.duration
            && lhs.positionInWindow == rhs.positionInWindow
            && lhs.isPlaceholder == rhs.isPlaceholder
            && lhs.adPlaybackState == rhs.adPlaybackState
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uid)
        hasher.combine(windowIndex)
        hasher.combine(duration)
        hasher.combine(positionInWindow)
        hasher.combine(isPlaceholder)
        hasher.combine(adPlaybackState)
    }
}
