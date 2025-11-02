//
//  Util.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 30.05.2025.
//

import Foundation

enum Util {
    // TODO: make indexUset as nil
    @inline(__always)
    static func binarySearchCeil<T: Comparable>(array: [T], value: T, inclusive: Bool, stayInBounds: Bool) -> Int {
        var index = array.binarySearch(value: value)

        if index < 0 {
            index = ~index
        } else {
            while index + 1 < array.count && array[index + 1] == value {
                index += 1
            }
            if inclusive { index -= 1 }
        }

        return stayInBounds ? min(array.count - 1, index) : index
    }

    // TODO: make indexUset as nil
    @inline(__always)
    static func binarySearch<T: Comparable>(array: [T], value: T, inclusive: Bool, stayInBounds: Bool) -> Int {
        var index = array.binarySearch(value: value)

        if index < 0 {
            index = -(index + 2)
        } else {
            while index > 0 && array[index - 1] == value {
                index -= 1
            }
            if inclusive { index += 1 }
        }

        return stayInBounds ? max(0, index) : index
    }

    @inline(__always)
    static func scaleLargeTimestamp(_ timestamp: Int64, multiplier: Int64, divisor: Int64) -> Int64 {
        scaleLargeValue(timestamp, multiplier: multiplier, divisor: divisor, roundingMode: .down)
    }

    @inline(__always)
    static func scaleLargeValue(
        _ value: Int64,
        multiplier: Int64,
        divisor: Int64,
        roundingMode: RoundingMode
    ) -> Int64 {
        guard value != 0, multiplier != 0 else { return 0 }

        if divisor >= multiplier, divisor % multiplier == 0 {
            let divisionFactor = Int64.divide(divisor, by: multiplier, roundingMode: .unnecessary)
            return Int64.divide(value, by: divisionFactor, roundingMode: roundingMode)

        } else if divisor < multiplier, multiplier % divisor == 0 {
            let multiplicationFactor = Int64.divide(multiplier, by: divisor, roundingMode: .unnecessary)
            return Int64.saturatedMultiply(value, multiplicationFactor)

        } else if divisor >= value, divisor % value == 0 {
            let divisionFactor = Int64.divide(divisor, by: value, roundingMode: .unnecessary)
            return Int64.divide(multiplier, by: divisionFactor, roundingMode: roundingMode)

        } else if divisor < value, value % divisor == 0 {
            let multiplicationFactor = Int64.divide(value, by: divisor, roundingMode: .unnecessary)
            return Int64.saturatedMultiply(multiplier, multiplicationFactor)
        }

        return scaleLargeValueFallback(
            value,
            multiplier: multiplier,
            divisor: divisor,
            roundingMode: roundingMode
        )
    }
}

extension Util {
    enum RoundingMode {
        case down
        case up
        case unnecessary
    }

    @inline(__always)
    private static func scaleLargeValueFallback(
        _ value: Int64,
        multiplier: Int64,
        divisor: Int64,
        roundingMode: RoundingMode
    ) -> Int64 {
        let decimalResult = (Decimal(value) * Decimal(multiplier)) / Decimal(divisor)

        let rounded: Decimal = {
            var tmp = decimalResult
            var result = Decimal()
            let mode: NSDecimalNumber.RoundingMode = {
                switch roundingMode {
                case .down:        return .down
                case .up:          return .up
                case .unnecessary: return .plain
                }
            }()
            NSDecimalRound(&result, &tmp, 0, mode)
            return result
        }()

        if roundingMode == .unnecessary && rounded != decimalResult {
            preconditionFailure("Rounding would be necessary")
        }

        // Clamp to 64-bit range.
        let asDouble = NSDecimalNumber(decimal: rounded).doubleValue
        if asDouble.isNaN { return 0 }
        if asDouble >= Double(Int64.max) { return Int64.max }
        if asDouble <= Double(Int64.min) { return Int64.min }
        return Int64(asDouble)
    }

}

private extension Int64 {
    @inline(__always)
    static func divide(
        _ dividend: Int64,
        by divisor: Int64,
        roundingMode: Util.RoundingMode
    ) -> Int64 {
        precondition(divisor != 0, "Division by zero")

        let quotient = dividend / divisor
        let remainder = dividend % divisor
        guard remainder != 0 else { return quotient }

        switch roundingMode {
        case .down:
            return quotient
        case .up:
            return quotient + ((dividend ^ divisor) >= 0 ? 1 : -1)
        case .unnecessary:
            preconditionFailure("Rounding would be necessary")
        }
    }

    @inline(__always)
    static func saturatedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return result }

        return (lhs ^ rhs) >= 0 ? .max : .min
    }
}

private extension Array where Element: Comparable {
    @inline(__always)
    func binarySearch(value: Element) -> Int {
        var low = 0
        var high = count - 1

        while low <= high {
            let mid = (low + high) >> 1
            if self[mid] < value {
                low = mid + 1
            } else if self[mid] > value {
                high = mid - 1
            } else {
                return mid
            }
        }

        return -(low + 1)
    }
}
