//
//  OSStatus+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.FoundationErrors

extension OSStatus {
    @discardableResult
    func validate() throws -> Bool {
        guard self == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(self))
        }
        return true
    }
}
