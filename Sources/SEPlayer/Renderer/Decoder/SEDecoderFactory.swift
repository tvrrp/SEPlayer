//
//  SEDecoderFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

import Foundation

public protocol SEDecoderFactory {
    func register<D: SEDecoder>(_ type: D.Type, _ make: @escaping (Queue, Format) throws -> D)
    func create<D: SEDecoder>(type: D.Type, queue: Queue, format: Format) throws -> D
}

final class DefaultSEDecoderFactory: SEDecoderFactory {
    private var registry: [ObjectIdentifier: (Queue, Format) throws -> any SEDecoder] = [:]
    private let lock = UnfairLock()

    func register<P: SEDecoder>(_ type: P.Type, _ make: @escaping (Queue, Format) throws -> P) {
        lock.withLock {
            registry[ObjectIdentifier(type)] = make
        }
    }

    func create<D: SEDecoder>(type: D.Type, queue: any Queue, format: Format) throws -> D {
        guard let factory = lock.withLock({ registry[ObjectIdentifier(type)] }) else {
            throw FactoryErrors.notRegistered
        }

        return try! factory(queue, format) as! D
    }
}

extension DefaultSEDecoderFactory {
    enum FactoryErrors: Error {
        case notRegistered
    }
}
