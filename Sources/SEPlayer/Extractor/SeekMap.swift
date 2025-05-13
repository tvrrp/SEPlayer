//
//  SeekMap.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol SeekMap {
    func isSeekable() -> Bool
    func getDuration() -> Int64
    func getSeekPoints(for time: Int64) -> SeekPoints
}

struct SeekPoints: Hashable {
    let first: SeekPoint
    let second: SeekPoint

    init(first: SeekPoint, second: SeekPoint? = nil) {
        self.first = first
        self.second = second ?? first
    }
}

extension SeekPoints {
    struct SeekPoint: Hashable {
        let time: Int64
        let position: Int

        static func start() -> SeekPoint {
            SeekPoint(time: 0, position: 0)
        }
    }
}
