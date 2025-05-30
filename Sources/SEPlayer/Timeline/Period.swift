//
//  Period.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

public struct Period: Hashable {
    let id: AnyHashable?
    var uid: AnyHashable?
    var windowIndex: Int
    let durationUs: Int64
    let positionInWindowUs: Int64
    var isPlaceholder: Bool

    public init(
        id: AnyHashable? = nil,
        uid: AnyHashable? = nil,
        windowIndex: Int = .zero,
        durationUs: Int64 = .zero,
        positionInWindowUs: Int64 = .zero,
        isPlaceholder: Bool = false
    ) {
        self.id = id
        self.uid = uid
        self.windowIndex = windowIndex
        self.durationUs = durationUs
        self.positionInWindowUs = positionInWindowUs
        self.isPlaceholder = isPlaceholder
    }
}
