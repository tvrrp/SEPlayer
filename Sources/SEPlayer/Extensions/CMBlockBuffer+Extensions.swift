//
//  CMBlockBuffer+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.03.2025.
//

import CoreMedia.CMBlockBuffer

extension CMBlockBuffer {
    enum Errors: OSStatus {
        case structureAllocationFailed = -12700
        case blockAllocationFailed = -12701
        case badCustomBlockSource = -12702
        case badOffsetParameter = -12703
        case badLengthParameter = -12704
        case badPointerParameter = -12705
        case emptyBlockBuffer = -12706
        case unallocatedBlock = -12707
        case insufficientSpace = -12708
    }
}
