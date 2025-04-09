//
//  MulticastDelegate.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public final class MulticastDelegate<T> {
    private let isThreadSafe: Bool
    private let delegates = NSHashTable<AnyObject>.weakObjects()
    private let queue = DispatchQueue(label: "com.SEPlayer.multicast.\(type(of: T.self))",
                                      attributes: .concurrent)

    public var count: Int {
        queue.sync {
            delegates.allObjects.count
        }
    }

    public convenience init() {
        self.init(isThreadSafe: true)
    }

    public init(isThreadSafe: Bool) {
        self.isThreadSafe = isThreadSafe
    }

    public func addDelegate(_ delegate: T) {
        guard conformsToClass(delegate) else {
            assertionFailure("Delegate object \(String(describing: type(of: delegate))) must be a class type!")
            return
        }
        if isThreadSafe {
            queue.sync(flags: .barrier) {
                delegates.add(delegate as AnyObject)
            }
        } else {
            delegates.add(delegate as AnyObject)
        }
    }

    public func removeDelegate(_ delegate: T) {
        guard conformsToClass(delegate) else {
            assertionFailure("Delegate object \(String(describing: type(of: delegate))) must be a class type!")
            return
        }
        if isThreadSafe {
            queue.sync(flags: .barrier) {
                delegates.remove(delegate as AnyObject)
            }
        } else {
            delegates.remove(delegate as AnyObject)
        }
    }

    public func removeAllDelegates() {
        if isThreadSafe {
            queue.sync(flags: .barrier) {
                delegates.removeAllObjects()
            }
        } else {
            delegates.removeAllObjects()
        }
    }

    public func invokeDelegates(_ invocation: (T) -> Void) {
        let observers: [AnyObject]
        if isThreadSafe {
            observers = queue.sync {
                delegates.allObjects
            }
        } else {
            observers = delegates.allObjects
        }

        observers.forEach { invocation($0 as! T) }
    }

    public func containsDelegate(_ delegate: T) -> Bool {
        guard conformsToClass(delegate) else {
            assertionFailure("Delegate object \(String(describing: type(of: delegate))) must be a class type!")
            return false
        }
        if isThreadSafe {
            return queue.sync {
                delegates.contains(delegate as AnyObject)
            }
        } else {
            return delegates.contains(delegate as AnyObject)
        }
    }

    // MARK: - Private

    private func conformsToClass(_ delegate: T) -> Bool {
        #if DEBUG
        let mirror = Mirror(reflecting: delegate)
        return mirror.displayStyle == .class
        #else
        return true
        #endif
    }
}
