//
//  DispatchTime+Extensions.swift
//  SEPlayer
//
//  Created by tvrrp on 17.02.2026.
//

import Dispatch

public extension DispatchTime {
    var milliseconds: Int64 {
        Int64(uptimeNanoseconds / 1_000_000)
    }
}

public extension DispatchTimeInterval {
    /// The interval in nanoseconds; `.never` is `Int64.max`.
    var totalNanoseconds: Int64 {
        switch self {
        case let .seconds(value): Int64(value) * 1_000_000_000
        case let .milliseconds(value): Int64(value) * 1_000_000
        case let .microseconds(value): Int64(value) * 1_000
        case let .nanoseconds(value): Int64(value)
        case .never: .max
        @unknown default: .max
        }
    }

    /// The interval in whole milliseconds; `.never` is `Int.max`.
    var totalMilliseconds: Int {
        self == .never ? .max : Int(totalNanoseconds / 1_000_000)
    }
}
