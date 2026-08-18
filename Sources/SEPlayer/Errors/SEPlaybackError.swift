//
//  SEPlaybackError.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import SEPlayerCommon

public struct SEPlaybackError: Error {
    public let type: ErrorSource
    public let mediaPeriodId: MediaPeriodId
    public let isRecoverable: Bool

    
}

public extension SEPlaybackError {
    enum ErrorSource {
        case mediaSource
        case renderer(RendererErrorType)
        case unexpected
        case remote
    }

    enum RendererErrorType {
        case rendererRequiresFlush
        case error(RendererError)
    }

    struct RendererError: Error {
        let rendererName: String
        let rendererIndex: Int
        let rendererFormat: Format?
        let rendererFormatSupport: RendererCapabilities.Support.FormatSupport?
    }
}
