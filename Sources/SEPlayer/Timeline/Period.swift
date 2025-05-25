//
//  Period.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

import Foundation

public struct Period: Hashable {
    let id: AnyHashable?
    var uuid: AnyHashable?
    var windowIndex: Int
    let durationUs: Int64
    let positionInWindowUs: Int64
    var isPlaceholder: Bool

    init(
        id: AnyHashable? = nil,
        uuid: AnyHashable? = nil,
        windowIndex: Int = .zero,
        durationUs: Int64 = .zero,
        positionInWindowUs: Int64 = .zero,
        isPlaceholder: Bool = false
    ) {
        self.id = id
        self.uuid = uuid
        self.windowIndex = windowIndex
        self.durationUs = durationUs
        self.positionInWindowUs = positionInWindowUs
        self.isPlaceholder = isPlaceholder
    }
}
