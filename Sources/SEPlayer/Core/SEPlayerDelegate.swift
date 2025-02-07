//
//  SEPlayerDelegate.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

@MainActor public protocol SEPlayerDelegate: AnyObject {
    func player(_ player: SEPlayer, didChangeState state: SEPlayer.State)
    func player(_ player: SEPlayer, didChangeTime time: Double)
    func player(_ player: SEPlayer, didChangeLoadedTime time: Double, progress: Double)
}

public extension SEPlayerDelegate {
    func player(_ player: SEPlayer, didChangeState state: SEPlayer.State) {}
    func player(_ player: SEPlayer, didChangeTime time: Double) {}
    func player(_ player: SEPlayer, didChangeLoadedTime time: Double, progress: Double) {}
}
