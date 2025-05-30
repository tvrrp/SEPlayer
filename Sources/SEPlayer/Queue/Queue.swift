//
//  Queue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Dispatch

public protocol Queue: AnyObject {
    // MARK: - Static

    static func mainQueue() -> Queue
    static func concurrentDefaultQueue() -> Queue
    static func concurrentBackgroundQueue() -> Queue

    // MARK: - Properties

    var queue: DispatchQueue { get }

    // MARK: - Interface

    func isCurrent() -> Bool

    func async(_ f: @escaping () -> Void)

    func sync<T>(_ f: () -> T) -> T
    func sync<T>(_ f: () throws -> T) rethrows -> T

    func justDispatch(_ f: @escaping () -> Void)
    func justDispatchWithQoS(qos: DispatchQoS, _ f: @escaping () -> Void)

    func after(_ delay: Double, _ f: @escaping () -> Void)
}
