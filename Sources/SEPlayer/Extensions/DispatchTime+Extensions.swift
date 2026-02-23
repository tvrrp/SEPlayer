//
//  DispatchTime+Extensions.swift
//  SEPlayer
//
//  Created by tvrrp on 17.02.2026.
//

import Dispatch

extension DispatchTime {
    var milliseconds: Int64 {
        Int64(uptimeNanoseconds / 1000)
    }
}
