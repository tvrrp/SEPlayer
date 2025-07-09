//
//  Period.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

public struct Period: Hashable {
    public let id: AnyHashable?
    internal(set) public var uid: AnyHashable?
    internal(set) public var windowIndex: Int
    public let durationUs: Int64
    public let positionInWindowUs: Int64
    internal(set) public var isPlaceholder: Bool

    init(
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
