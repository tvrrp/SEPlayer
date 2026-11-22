//
//  RendererConfiguration.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.RendererConfiguration
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

public struct RendererConfiguration: Equatable {
    public let tunneling: Bool

    public init(tunneling: Bool = false) {
        self.tunneling = tunneling
    }
}
