//
//  Allocation.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

final class Allocation {
    var data: UnsafeMutableRawBufferPointer {
        get {
            assert(queue.isCurrent())
            return _data
        }
    }

    let offset: Int

    private let queue: Queue
    private let _data: UnsafeMutableRawBufferPointer

    func getData<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        try queue.sync { try body(self._data) }
    }

    init(queue: Queue, data: UnsafeMutableRawBufferPointer, offset: Int) {
        self.queue = queue
        self._data = data
        self.offset = offset
    }
}
