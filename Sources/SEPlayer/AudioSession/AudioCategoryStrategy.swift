//
//  AudioCategoryStrategy.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2025.
//

//public struct AudioCategory: Comparable {
//    
//}

public enum AudioCategoryStrategy: Int, Comparable, Equatable {
    case `default` = 0
    case mixWithOthers = 1
    case playback = 2
//    case custom(AudioCategory)

    public static func < (lhs: AudioCategoryStrategy, rhs: AudioCategoryStrategy) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
