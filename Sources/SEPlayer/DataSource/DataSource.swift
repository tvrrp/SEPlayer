//
//  DataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSURLSession

public protocol DataSource: DataReader {
    var url: URL? { get }
    var urlResponse: HTTPURLResponse? { get }
    nonisolated var components: DataSourceOpaque { get }
    @discardableResult func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int
    @discardableResult func close(isolation: isolated any Actor) async -> ByteBuffer?
}

extension DataSource {
    nonisolated func addTransferListener(_ listener: TransferListener) {
        components.transferListeners.addDelegate(listener)
    }

    nonisolated func transferInitializing(source: DataSource) {
        components.transferListeners.invokeDelegates {
            $0.onTransferInitializing(source: source, isNetwork: components.isNetwork)
        }
    }

    nonisolated func transferEnded(source: DataSource, metrics: URLSessionTaskMetrics) {
        components.transferListeners.invokeDelegates {
            $0.onTransferEnd(source: source, isNetwork: components.isNetwork, metrics: metrics)
        }
    }
}

public final class DataSourceOpaque {
    fileprivate let isNetwork: Bool
    fileprivate let transferListeners = MulticastDelegate<TransferListener>(isThreadSafe: true)

    public init(isNetwork: Bool) { self.isNetwork = isNetwork }
}
