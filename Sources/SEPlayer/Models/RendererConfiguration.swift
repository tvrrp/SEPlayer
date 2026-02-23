//
//  RendererConfiguration.swift
//  SEPlayer
//
//  Created by tvrrp on 13.02.2026.
//

public struct RendererConfiguration: Equatable {
    public let tunneling: Bool

    public init(tunneling: Bool = false) {
        self.tunneling = tunneling
    }
}
