//
//  SeekMap.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol SeekMap {
    func isSeekable() -> Bool
    func getDuration() -> CMTime
    func getSeekPoints(for time: CMTime) -> SeekPoints
}

struct SeekPoints: Hashable {
    let first: SeekPoint
    let second: SeekPoint?

    init(first: SeekPoint, second: SeekPoint? = nil) {
        self.first = first
        self.second = second
    }
}

extension SeekPoints {
    struct SeekPoint: Hashable {
        let time: CMTime
        let position: Int

        static func start() -> SeekPoint {
            SeekPoint(time: .zero, position: 0)
        }
    }
}
