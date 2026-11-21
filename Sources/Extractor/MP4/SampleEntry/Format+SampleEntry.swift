//
//  Format+SampleEntry.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import Foundation
import SEPlayerCommon

extension Format {
    /// Keeps the whole sample entry, copied out of the container.
    ///
    /// - Parameter entry: The entry, from its size field.
    mutating func setSampleEntry(_ entry: BlockBufferReader, isQuickTime: Bool) throws {
        self.sampleEntry = try SampleEntry(bytes: entry.readableData(), isQuickTime: isQuickTime)
    }

    /// Keeps the boxes of the sample entry, in their order, copied out of the container. Padding isn't kept.
    mutating func keepBoxes(_ boxes: [SampleEntryBox]) throws {
        self.boxes = try boxes.filter { $0.type != .free }.map { box in
            try MediaBox(type: FourCharacterCode(box.rawType), payload: box.payload.readableData())
        }
    }
}

extension [SampleEntryBox] {
    /// The payload of the first box of `type`.
    func payload(of type: MP4Box.BoxType) -> BlockBufferReader? {
        first { $0.rawType == type.rawValue }?.payload
    }
}
