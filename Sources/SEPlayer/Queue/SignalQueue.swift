//
//  SignalQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

private let QueueSpecificKey = DispatchSpecificKey<NSObject>()

private let globalMainQueue = SignalQueue(queue: DispatchQueue.main, specialIsMainQueue: true)
private let globalDefaultQueue = SignalQueue(queue: DispatchQueue.global(qos: .default), specialIsMainQueue: false)
private let globalBackgroundQueue = SignalQueue(queue: DispatchQueue.global(qos: .background), specialIsMainQueue: false)

final class SignalQueue: Queue {
    // MARK: - Class

    static func mainQueue() -> Queue {
        globalMainQueue
    }

    static func concurrentDefaultQueue() -> Queue {
        globalDefaultQueue
    }

    static func concurrentBackgroundQueue() -> Queue {
        globalBackgroundQueue
    }

    // MARK: - Properties

    var queue: DispatchQueue { nativeQueue }

    private let nativeQueue: DispatchQueue
    private let specific = NSObject()
    private let specialIsMainQueue: Bool

    // MARK: - Init

    init(queue: DispatchQueue) {
        nativeQueue = queue
        specialIsMainQueue = false
    }

    fileprivate init(queue: DispatchQueue, specialIsMainQueue: Bool) {
        nativeQueue = queue
        self.specialIsMainQueue = specialIsMainQueue
    }

    init(name: String? = nil, qos: DispatchQoS = .default) {
        nativeQueue = DispatchQueue(label: name ?? "", qos: qos)

        specialIsMainQueue = false

        nativeQueue.setSpecific(key: QueueSpecificKey, value: specific)
    }

    // MARK: - Interface

    func isCurrent() -> Bool {
        if DispatchQueue.getSpecific(key: QueueSpecificKey) === specific {
            return true
        } else if specialIsMainQueue && Thread.isMainThread {
            return true
        } else {
            return false
        }
    }

    func async(_ f: @escaping () -> Void) {
        if isCurrent() {
            f()
        } else {
            nativeQueue.async(execute: f)
        }
    }

    func sync<T>(_ f: () -> T) -> T {
        if isCurrent() {
            return f()
        } else {
            return nativeQueue.sync(execute: f)
        }
    }
    
    func sync<T>(_ f: () throws -> T) rethrows -> T {
        if isCurrent() {
            return try f()
        } else {
            return try nativeQueue.sync(execute: f)
        }
    }

    func justDispatch(_ f: @escaping () -> Void) {
        nativeQueue.async(execute: f)
    }

    func justDispatchWithQoS(qos: DispatchQoS, _ f: @escaping () -> Void) {
        nativeQueue.async(group: nil, qos: qos, flags: [.enforceQoS], execute: f)
    }

    func after(_ delay: Double, _ f: @escaping () -> Void) {
        let time = DispatchTime.now() + delay
        nativeQueue.asyncAfter(deadline: time, execute: f)
    }
}
