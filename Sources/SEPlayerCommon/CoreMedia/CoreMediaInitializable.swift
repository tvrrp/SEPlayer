//
//  CoreMediaInitializable.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import CoreMedia

/// Gives CoreMedia types Swift initializers.
///
/// Extensions of Core Foundation types can't declare initializers, but initializers of a protocol they conform to,
/// constrained to one of them, can assign `self`.
public protocol _CoreMediaInitializable {}

extension CMBlockBuffer: _CoreMediaInitializable {}
extension CMSampleBuffer: _CoreMediaInitializable {}
extension CMFormatDescription: _CoreMediaInitializable {}
extension CMTimebase: _CoreMediaInitializable {}
extension CMMemoryPool: _CoreMediaInitializable {}
