//
//  GaplessInfoHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 30.06.2025.
//

import SEPlayerCommon

public  struct GaplessInfoHolder {
    public let encoderDelay: Int
    public let encoderPadding: Int

    public init(encoderDelay: Int, encoderPadding: Int) {
        self.encoderDelay = encoderDelay
        self.encoderPadding = encoderPadding
    }

    public init() {
        encoderDelay = Format.noValue
        encoderPadding = Format.noValue
    }
}
