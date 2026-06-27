//
//  Range+Extensions.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import Foundation

public extension Range where Bound == Int {

    /// True iff every element of `other` lies within `self`.
    func contains(_ other: Range<Int>) -> Bool {
        lowerBound <= other.lowerBound && upperBound >= other.upperBound
    }

    /// True if the two ranges share at least one element.
    func overlaps(_ other: Range<Int>) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }

    func intersection(with other: Range<Int>) -> Range<Int>? {
        let lo = max(lowerBound, other.lowerBound)
        let hi = min(upperBound, other.upperBound)
        return lo < hi ? lo..<hi : nil
    }
}
