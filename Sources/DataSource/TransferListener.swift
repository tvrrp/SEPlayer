//
//  TransferListener.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Dispatch
import Foundation.NSURLSession

public protocol TransferListener {
    func onTransferInitializing(source: DataSource, isNetwork: Bool)
    func onTransferEnd(source: DataSource, isNetwork: Bool, metrics: URLSessionTaskMetrics)
    /// Called as a network request of a source is sent, answered, delivers bytes and ends.
    ///
    /// Called on the network queue, as the events happen: listeners must not block.
    func onNetworkTransfer(_ event: NetworkTransferEvent)
}

public extension TransferListener {
    func onNetworkTransfer(_ event: NetworkTransferEvent) {}
}

/// What happened to one network request, and when.
///
/// The events of a request come in order: `requestSent`, `responseReceived`, any number of `bytesReceived`, then
/// `requestEnded`, which may come at any point and always comes last.
public struct NetworkTransferEvent: Sendable {
    public enum Kind: Sendable {
        /// The request was sent.
        case requestSent
        /// The response headers arrived. `expectedBytes` is the length of the body, if known.
        case responseReceived(expectedBytes: Int?)
        /// Bytes of the body arrived.
        case bytesReceived(Int)
        /// The request finished, failed or was cancelled: no more bytes arrive for it.
        case requestEnded
    }

    /// Identifies the request among the events of the process.
    public let requestId: UInt64
    public let kind: Kind
    /// When it happened, in `DispatchTime.uptimeNanoseconds`.
    public let time: UInt64

    public init(requestId: UInt64, kind: Kind, time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.requestId = requestId
        self.kind = kind
        self.time = time
    }
}
