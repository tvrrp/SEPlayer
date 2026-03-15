//
//  DataType.swift
//  SEPlayer
//
//  Created by tvrrp on 25.02.2026.
//

@frozen public enum DataType {
    case unknown
    case media
    case mediaInitialization
    case drm
    case manifest
    case timeSynchronization
    case ad
    case mediaProgressiveLive
}
