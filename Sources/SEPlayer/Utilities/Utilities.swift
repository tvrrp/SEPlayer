//
//  Utilities.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

@inlinable
internal func debugOnly(_ body: () -> Void) {
    assert(
        {
            body()
            return true
        }()
    )
}
