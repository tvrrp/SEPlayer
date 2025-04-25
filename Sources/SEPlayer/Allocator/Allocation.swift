//
//  Allocation.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

final class Allocation {
    var data: UnsafeMutableRawBufferPointer {
        get {
//            assert(queue.isCurrent())
            return _data
        }
    }

    var baseAddress: UnsafeMutableRawPointer! {
        get {
//            assert(queue.isCurrent())
            return _data.baseAddress!.advanced(by: offset)
        }
    }

    let offset: Int
    let size: Int
    let isNode: Bool

    private let queue: Queue
    private let _data: UnsafeMutableRawBufferPointer

    init(queue: Queue, data: UnsafeMutableRawBufferPointer, offset: Int = 0, size: Int, isNode: Bool = false) {
        self.queue = queue
        self._data = data
        self.offset = offset
        self.size = size
        self.isNode = isNode
    }

    func getData<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
//        try queue.sync { try body(self._data) }
        try body(self._data)
    }

    func createNode(from offset: Int) -> Allocation {
        assert(queue.isCurrent());
        let newSize = size - offset
        return Allocation(
            queue: queue,
            data: UnsafeMutableRawBufferPointer(
                start: _data.baseAddress!.advanced(by: offset + self.offset), count: newSize
            ),
            size: newSize, isNode: true
        )
    }
}

final class Allocation2 {
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
