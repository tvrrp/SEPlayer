//
//  MulticastDelegate.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Atomics

/// Delegates held weakly and called in the order they were added, from any thread.
///
/// A call reads an immutable snapshot of the delegates through an atomic pointer and takes no lock. Adding or removing
/// a delegate publishes a new snapshot; a replaced one is freed once no call is reading it.
public final class MulticastDelegate<T> {
    /// The number of delegates that are still alive.
    public var count: Int {
        withSnapshot { $0.pointee.entries.count }
    }

    private let head: UnsafeAtomic<UnsafeMutablePointer<Snapshot>>
    /// The number of calls reading a snapshot.
    private let readers: UnsafeAtomic<Int>
    /// Snapshots replaced while a call was reading them. Its lock also orders the changes.
    private let retired = UnfairMutex<[UnsafeMutablePointer<Snapshot>]>([])

    public init() {
        head = .create(Snapshot.make([]))
        readers = .create(0)
    }

    deinit {
        Snapshot.free(head.load(ordering: .relaxed))
        head.destroy()
        readers.destroy()
        retired.withLock { $0.forEach(Snapshot.free) }
    }

    public func addDelegate(_ delegate: T) {
        assert(type(of: delegate as Any) is AnyClass, "Delegate \(type(of: delegate as Any)) must be a class instance")
        let object = delegate as AnyObject
        update { entries in
            if !entries.contains(where: { $0.object === object }) {
                entries.append(Entry(object: object, delegate: delegate))
            }
        }
    }

    public func removeDelegate(_ delegate: T) {
        let object = delegate as AnyObject
        update { entries in entries.removeAll { $0.object === object } }
    }

    public func removeAllDelegates() {
        update { entries in entries.removeAll() }
    }

    public func invokeDelegates(_ invocation: (T) throws -> Void) rethrows {
        try withSnapshot { try $0.pointee.forEach(invocation) }
    }

    public func containsDelegate(_ delegate: T) -> Bool {
        let object = delegate as AnyObject
        return withSnapshot { $0.pointee.entries.contains { $0.object === object } }
    }

    private func withSnapshot<R>(_ body: (UnsafeMutablePointer<Snapshot>) throws -> R) rethrows -> R {
        // Sequentially consistent with the check in `update`: either it sees this call, or this call loads the
        // snapshot it published.
        readers.wrappingIncrement(ordering: .sequentiallyConsistent)
        defer { readers.wrappingDecrement(ordering: .releasing) }
        return try body(head.load(ordering: .sequentiallyConsistent))
    }

    private func update(_ change: (inout [Entry]) -> Void) {
        // Holds the delegates strongly until after the lock, removed ones included: a last release runs a deinit,
        // which may remove its delegate from here.
        var current: [Entry] = []
        retired.withLock { retired in
            let old = head.load(ordering: .relaxed)
            current = old.pointee.entries
            var entries = current
            change(&entries)
            head.store(Snapshot.make(entries), ordering: .sequentiallyConsistent)
            retired.append(old)
            // With no call reading, later calls load the new snapshot.
            if readers.load(ordering: .sequentiallyConsistent) == 0 {
                retired.forEach(Snapshot.free)
                retired.removeAll()
            }
        }
    }
}

private extension MulticastDelegate {
    struct Entry {
        let object: AnyObject
        let delegate: T
    }

    /// An immutable list of delegates.
    ///
    /// Each delegate is a weak reference and a copy of its `T` value that holds no reference. A copy is only read
    /// while the weak load of its object holds the object, so a call needs no cast from `AnyObject` to `T`.
    struct Snapshot {
        let count: Int
        let objects: UnsafeMutablePointer<WeakReference>
        let delegates: UnsafeMutablePointer<T>

        /// The delegates that are still alive.
        var entries: [Entry] {
            var entries: [Entry] = []
            entries.reserveCapacity(count)
            for index in 0 ..< count {
                guard let object = objects[index].object else { continue }
                entries.append(Entry(object: object, delegate: delegates[index]))
            }
            return entries
        }

        static func make(_ entries: [Entry]) -> UnsafeMutablePointer<Snapshot> {
            let objects = UnsafeMutablePointer<WeakReference>.allocate(capacity: entries.count)
            let delegates = UnsafeMutablePointer<T>.allocate(capacity: entries.count)
            for index in entries.indices {
                (objects + index).initialize(to: WeakReference(object: entries[index].object))
                // Copies the bytes only, so the copy holds no reference.
                withUnsafeBytes(of: entries[index].delegate) { bytes in
                    guard let source = bytes.baseAddress else { return }
                    UnsafeMutableRawPointer(delegates + index).copyMemory(from: source, byteCount: bytes.count)
                }
            }
            let snapshot = UnsafeMutablePointer<Snapshot>.allocate(capacity: 1)
            snapshot.initialize(to: Snapshot(count: entries.count, objects: objects, delegates: delegates))
            return snapshot
        }

        static func free(_ snapshot: UnsafeMutablePointer<Snapshot>) {
            snapshot.pointee.objects.deinitialize(count: snapshot.pointee.count)
            snapshot.pointee.objects.deallocate()
            // The copies hold no references, so there's nothing to deinitialize.
            snapshot.pointee.delegates.deallocate()
            snapshot.deallocate()
        }

        func forEach(_ body: (T) throws -> Void) rethrows {
            for index in 0 ..< count {
                // Loads in place: copying a weak reference costs two side-table atomics.
                guard let object = objects[index].object else { continue }
                try withExtendedLifetime(object) {
                    try body(delegates[index])
                }
            }
        }
    }
}

private struct WeakReference {
    weak var object: AnyObject?
}
