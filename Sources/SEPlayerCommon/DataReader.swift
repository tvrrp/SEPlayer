//
//  DataReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.DataReader
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

public protocol DataReader {
    var isolation: any Actor { get }
    func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer?
}
