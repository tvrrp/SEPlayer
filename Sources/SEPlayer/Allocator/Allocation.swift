//
//  Allocation.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

final class Allocation {
    let data: UnsafeMutableRawPointer
    let capacity: Int

    init(data: UnsafeMutableRawPointer, capacity: Int) {
        self.data = data
        self.capacity = capacity
    }

    deinit {
        data.deallocate()
    }
}
