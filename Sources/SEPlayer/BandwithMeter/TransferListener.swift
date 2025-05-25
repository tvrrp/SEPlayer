//
//  TransferListener.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public protocol TransferListener {
    var id: UUID { get }
    func onTransferInitializing(source: DataSource, isNetwork: Bool)
    func onTransferEnd(source: DataSource, isNetwork: Bool, metrics: URLSessionTaskMetrics)
}
