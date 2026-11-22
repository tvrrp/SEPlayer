//
//  GaplessInfoHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.GaplessInfoHolder
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

/// The encoder delay and padding of an audio stream: the samples at its start and end that aren't part of it.
public struct GaplessInfoHolder {
    public var encoderDelay: Int?
    public var encoderPadding: Int?

    public var hasGaplessInfo: Bool {
        encoderDelay != nil && encoderPadding != nil
    }

    public init(encoderDelay: Int? = nil, encoderPadding: Int? = nil) {
        self.encoderDelay = encoderDelay
        self.encoderPadding = encoderPadding
    }

    /// Reads the iTunes gapless information (`iTunSMPB`) of ID3 comment frames or MP4 internal frames.
    ///
    /// - Returns: Whether some was found.
    @discardableResult
    public mutating func setFromMetadata(_ metadata: Metadata) -> Bool {
        let comments = metadata.entries.compactMap { entry -> String? in
            if let frame = entry as? CommentFrame, frame.commentDescription == Self.gaplessDescription {
                return frame.text
            }
            if let frame = entry as? InternalFrame,
               frame.domain == Self.gaplessDomain,
               frame.frameDescription == Self.gaplessDescription {
                return frame.text
            }
            return nil
        }
        return comments.contains { setFromComment($0) }
    }

    /// Reads ` XXXXXXXX DDDDDDDD PPPPPPPP`: three hex fields of eight digits after a space each, the last two the
    /// delay and the padding.
    private mutating func setFromComment(_ comment: String) -> Bool {
        let fields = comment.split(separator: " ", omittingEmptySubsequences: false)
        // The first field is empty: the comment starts with a space.
        guard fields.count >= 4, fields[0].isEmpty else { return false }

        let hexFields = fields[1 ... 3]
        guard hexFields.allSatisfy({ $0.count >= Self.hexFieldLength }) else {
            return false
        }
        guard let encoderDelay = Int(fields[2].prefix(Self.hexFieldLength), radix: 16),
              let encoderPadding = Int(fields[3].prefix(Self.hexFieldLength), radix: 16) else {
            return false
        }
        guard encoderDelay > 0 || encoderPadding > 0 else { return false }

        self.encoderDelay = encoderDelay
        self.encoderPadding = encoderPadding
        return true
    }
}

private extension GaplessInfoHolder {
    static let gaplessDomain = "com.apple.iTunes"
    static let gaplessDescription = "iTunSMPB"
    static let hexFieldLength = 8
}
