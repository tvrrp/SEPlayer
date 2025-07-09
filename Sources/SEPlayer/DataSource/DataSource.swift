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
    var queue: Queue { get }
    var components: DataSourceOpaque { get }
    @discardableResult func open(dataSpec: DataSpec) throws -> Int
    @discardableResult func close() -> ByteBuffer?
}

extension DataSource {
    func addTransferListener(_ listener: TransferListener) {
        components.transferListeners.addDelegate(listener)
    }

    func transferInitializing(source: DataSource) {
        components.transferListeners.invokeDelegates {
            $0.onTransferInitializing(source: source, isNetwork: components.isNetwork)
        }
    }

    func transferEnded(source: DataSource, metrics: URLSessionTaskMetrics) {
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
