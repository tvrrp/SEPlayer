//
//  Period.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

public final class Period {
    private(set) public var id: AnyHashable?
    internal(set) public var uid: AnyHashable?
    internal(set) public var windowIndex: Int = .zero
    private(set) public var durationUs: Int64 = .zero
    private(set) public var positionInWindowUs: Int64 = .zero
    internal(set) public var isPlaceholder: Bool = false
    private(set) public var adPlaybackState: AdPlaybackState

    init() {
        adPlaybackState = .none
    }

    @discardableResult
    public func set(
        id: AnyHashable?,
        uid: AnyHashable?,
        windowIndex: Int,
        durationUs: Int64,
        positionInWindowUs: Int64,
        adPlaybackState: AdPlaybackState = .none,
        isPlaceholder: Bool = false,
    ) -> Period {
        self.id = id
        self.uid = uid
        self.windowIndex = windowIndex
        self.durationUs = durationUs
        self.positionInWindowUs = positionInWindowUs
        self.adPlaybackState = adPlaybackState
        self.isPlaceholder = isPlaceholder
        return self
    }

    init(
        id: AnyHashable? = nil,
        uid: AnyHashable? = nil,
        windowIndex: Int = .zero,
        durationUs: Int64 = .zero,
        positionInWindowUs: Int64 = .zero,
        isPlaceholder: Bool = false,
        adPlaybackState: AdPlaybackState = .none
    ) {
        self.id = id
        self.uid = uid
        self.windowIndex = windowIndex
        self.durationUs = durationUs
        self.positionInWindowUs = positionInWindowUs
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
            && lhs.durationUs == rhs.durationUs
            && lhs.positionInWindowUs == rhs.positionInWindowUs
            && lhs.isPlaceholder == rhs.isPlaceholder
            && lhs.adPlaybackState == rhs.adPlaybackState
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uid)
        hasher.combine(windowIndex)
        hasher.combine(durationUs)
        hasher.combine(positionInWindowUs)
        hasher.combine(isPlaceholder)
        hasher.combine(adPlaybackState)
    }
}
