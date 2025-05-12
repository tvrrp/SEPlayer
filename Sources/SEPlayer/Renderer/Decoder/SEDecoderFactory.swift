//
//  SEDecoderFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

import CoreMedia

protocol SEDecoderFactory {
    func register<D: SEDecoder>(_ type: D.Type, _ make: @escaping (Queue, CMFormatDescription) throws -> D)
    func create<D: SEDecoder>(type: D.Type, queue: Queue, format: CMFormatDescription) throws -> D
}

final class DefaultSEDecoderFactory: SEDecoderFactory {
    private var registry: [ObjectIdentifier: (Queue, CMFormatDescription) throws -> any SEDecoder] = [:]
    private let lock = NSLock()

    func register<P: SEDecoder>(_ type: P.Type, _ make: @escaping (Queue, CMFormatDescription) throws -> P) {
        lock.withLock {
            registry[ObjectIdentifier(type)] = make
        }
    }

    func create<D: SEDecoder>(type: D.Type, queue: any Queue, format: CMFormatDescription) throws -> D {
        guard let factory = lock.withLock({ registry[ObjectIdentifier(type)] }) else {
            throw FactoryErrors.notRegistered
        }

        return try factory(queue, format) as! D
    }
}

extension DefaultSEDecoderFactory {
    enum FactoryErrors: Error {
        case notRegistered
    }
}
