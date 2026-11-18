//
//  ProResUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

/// Describes Apple ProRes sample entries.
enum ProResUtil {
    static let formats: Set<MP4Box.BoxType> = [
        .apco, .apcs, .apcn, .apch, .ap4h, .ap4x, .ap0h, .ap2h, .aprh, .aprl, .aprn,
    ]

    /// The bits of each component: 16 for ProRes RAW HQ and RAW, and for 4444 with alpha; 12 otherwise.
    static func bitsPerComponent(format: MP4Box.BoxType, depth: Int) -> Int {
        switch format {
        case .aprh, .aprn: 16
        case .ap4h, .ap4x: depth == 32 ? 16 : 12
        default: 12
        }
    }
}
