//
//  SequenceableLoader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.SequenceableLoader
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

public protocol SequenceableLoaderCallback {
    associatedtype Source

    func continueLoadingRequested(with source: Source)
}

public protocol SequenceableLoader {
    var isLoading: Bool { get }

    func getBufferedPosition() -> CMTime
    func getNextLoadPosition() -> CMTime

    @discardableResult
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool
    func stopLoading()
    func reevaluateBuffer(position: CMTime)
}

public extension SequenceableLoader {
    func reevaluateBuffer(position: CMTime) {}
}
