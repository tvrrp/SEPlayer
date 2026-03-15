//
//  Cue.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import Foundation

public struct Cue: Codable, @unchecked Sendable {
    public let text: String?
//    public let image: CGImage?
    public let zIndex: Int

    init(builder: Builder) {
        text = builder.text
//        image = builder.image
        zIndex = builder.zIndex
    }

    func buildUpon() -> Builder {
        Builder(cue: self)
    }

//    public init(from decoder: any Decoder) throws {
//        
//    }
//
//    public func encode(to encoder: any Encoder) throws {
//        
//    }
}

public extension Cue {
    final class Builder {
        var text: String?
//        var image: CGImage?
        var zIndex: Int = 0

        public init() {}

        init(cue: Cue) {
            text = cue.text
//            image = cue.image
            zIndex = cue.zIndex
        }

        public func build() -> Cue {
            Cue(builder: self)
        }

        public func setText(_ text: String) -> Builder {
            self.text = text
            return self
        }
    }
}

extension NSAttributedString: @retroactive @unchecked Sendable {}
