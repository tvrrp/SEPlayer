//
//  GaplessInfoHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 30.06.2025.
//

struct GaplessInfoHolder {
    let encoderDelay: Int
    let encoderPadding: Int

    init(encoderDelay: Int, encoderPadding: Int) {
        self.encoderDelay = encoderDelay
        self.encoderPadding = encoderPadding
    }

    init() {
        encoderDelay = Format.noValue
        encoderPadding = Format.noValue
    }
}
