//
//  MP4SniffFailures.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.06.2025.
//

struct AtomSizeTooSmallSniffFailure: SniffFailure {
    let atomType: MP4Box.BoxType?
    let atomSize: Int
    let minimumHeaderSize: Int
}

public struct IncorrectFragmentationSniffFailure: SniffFailure {
    let fileIsFragmented: Bool

    private init(fileIsFragmented: Bool) {
        self.fileIsFragmented = fileIsFragmented
    }

    static func fileFragmented() -> Self {
        Self.init(fileIsFragmented: true)
    }

    static func fileNotFragmented() -> Self {
        Self.init(fileIsFragmented: false)
    }
}

public struct NoDeclaredBrandSniffFailure: SniffFailure {}

public struct UnsupportedBrandsSniffFailure: SniffFailure {
    let majorBrand: UInt32
    let compatibleBrands: [UInt32]
}
