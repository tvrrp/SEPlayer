//
//  LoadControl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.05.2025.
//

public protocol LoadControl {
    func getAllocator() -> Allocator
}

struct DefaultLoadControl: LoadControl {
    private let queue: Queue
    private let allocator: Allocator

    init(queue: Queue) {
        self.queue = queue
        self.allocator = DefaultAllocator(queue: queue)
    }

    func getAllocator() -> Allocator { allocator }
}
