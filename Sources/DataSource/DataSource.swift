//
//  DataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSURLSession
import SEPlayerCommon

public protocol DataSource: DataReader, AnyObject {
    nonisolated var components: DataSourceOpaque { get }
    func getContentLenght(dataSpec: DataSpec, _ isolation: isolated any Actor) -> Int?
    func close(_ isolation: isolated any Actor) async throws
    func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse?
    func canHandle(new dataSpec: DataSpec, _ isolation: isolated any Actor) -> Bool
}

public extension DataSource {
    func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse? { nil }

    func getContentLenght(dataSpec: DataSpec, _ isolation: isolated any Actor) -> Int? {
        guard let total = getURLResponse(isolation)?.resourceLength else {
            return nil
        }

        let available = total - dataSpec.position
        guard let length = dataSpec.length else { return available }
        return min(length, available)
    }
}

public extension DataSource {
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

public final class DataSourceOpaque: @unchecked Sendable {
    fileprivate let isNetwork: Bool
    fileprivate let transferListeners = MulticastDelegate<TransferListener>(isThreadSafe: true)

    public init(isNetwork: Bool) { self.isNetwork = isNetwork }
}
