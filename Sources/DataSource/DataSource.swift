//
//  DataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSURLSession
import SEPlayerCommon

/// A source of bytes, such as a file or an HTTP resource.
///
/// A source is opened for a ``DataSpec``, read within it, and closed. It can be opened again once closed.
public protocol DataSource: DataReader, AnyObject {
    nonisolated var components: DataSourceOpaque { get }
    /// Opens the source to read `dataSpec`.
    ///
    /// - Returns: The number of bytes `dataSpec` reads, or `nil` if the source doesn't know it.
    func open(dataSpec: DataSpec, _ isolation: isolated any Actor) async throws -> Int?
    /// Closes the source. A source that isn't open closes without error.
    func close(_ isolation: isolated any Actor) async throws
    /// The response of the server, for a source that read from one.
    func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse?
    /// Lets the consumer decide how far the source loads ahead of its reads, and learn how much it holds there.
    /// Applies from the next ``open(dataSpec:_:)`` on.
    func setReadAhead(_ readAhead: ReadAhead?)
}

public extension DataSource {
    func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse? { nil }
    func setReadAhead(_ readAhead: ReadAhead?) {}
}

public extension DataSource {
    /// Whether the source reads from the network.
    nonisolated var isNetwork: Bool { components.isNetwork }

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

    func networkTransfer(_ event: NetworkTransferEvent) {
        transferListeners.invokeDelegates { $0.onNetworkTransfer(event) }
    }
}
