//
//  BandwidthMeter.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.05.2025.
//

import Foundation.NSURLSession

public protocol BandwidthMeterDelegate {
    
}

public protocol BandwidthMeter {
    var delegate: MulticastDelegate<BandwidthMeterDelegate> { get }
    var transferListener: TransferListener { get }
}

final class DefaultBandwidthMeter: BandwidthMeter {
    let delegate = MulticastDelegate<BandwidthMeterDelegate>(isThreadSafe: true)
    var transferListener: TransferListener { self }
}

extension DefaultBandwidthMeter: TransferListener {
    func onTransferInitializing(source: DataSource, isNetwork: Bool) {
        
    }

    func onTransferEnd(source: DataSource, isNetwork: Bool, metrics: URLSessionTaskMetrics) {
        
    }
}
