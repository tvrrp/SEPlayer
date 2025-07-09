//
//  DecoderReinitializationState.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

enum DecoderReinitializationState {
    case none
    case signalEndOfStream
    case waitEndOfStream
    case backgroundInactivity
}
