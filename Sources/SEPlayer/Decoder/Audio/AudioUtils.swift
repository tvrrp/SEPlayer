//
//  AudioUtils.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.04.2025.
//

enum AudioUtils {
    static func mediaDurationFor(playoutDuration: Int64, speed: Float) -> Int64 {
        guard speed != 1 else { return playoutDuration }

        let result = (Double(playoutDuration) * Double(speed)).rounded(.up)
        return Int64(result)
    }

    static func sampleCountToDuration(sampleCount: Int64, sampleRate: Int) -> Int64 {
        scaleLargeValue(value: sampleCount, multiplier: Int64.microsecondsPerSecond, divisor: Int64(sampleRate), roundingMode: .down)
    }

    static func durationToSampleCount(duration: Int64, sampleRate: Int) -> Int64 {
        scaleLargeValue(value: duration, multiplier: Int64(sampleRate), divisor: Int64.microsecondsPerSecond, roundingMode: .up)
    }

    private static func scaleLargeValue(value: Int64, multiplier: Int64, divisor: Int64, roundingMode: FloatingPointRoundingRule) -> Int64 {
        if value == 0 || multiplier == 0 {
            return 0
        }

        if divisor >= multiplier, divisor % multiplier == 0 {
            let divisionFactor = divisor / multiplier
            return divide(value, by: divisionFactor, roundingMode: roundingMode)
        } else if divisor < multiplier, multiplier % divisor == 0 {
            let multiplicationFactor = multiplier / divisor
            return saturatedMultiply(value, by: multiplicationFactor)
        } else if divisor >= value, divisor % value == 0 {
            let divisionFactor = divisor / value
            return divide(multiplier, by: divisionFactor, roundingMode: roundingMode)
        } else if divisor < value, value % divisor == 0 {
            let multiplicationFactor = value / divisor
            return saturatedMultiply(multiplier, by: multiplicationFactor)
        } else {
            return scaleLargeValueFallback(value: value, multiplier: multiplier, divisor: divisor, roundingMode: roundingMode)
        }
    }

    private static func divide(_ value: Int64, by divisor: Int64, roundingMode: FloatingPointRoundingRule) -> Int64 {
        let result = Double(value) / Double(divisor)
        return Int64(result.rounded(roundingMode))
    }

    private static func saturatedMultiply(_ value: Int64, by multiplier: Int64) -> Int64 {
        let multipledResult = value.multipliedReportingOverflow(by: multiplier)
        return multipledResult.overflow ? (value > 0 ? Int64.max : Int64.min) : multipledResult.partialValue
    }

    private static func scaleLargeValueFallback(value: Int64, multiplier: Int64, divisor: Int64, roundingMode: FloatingPointRoundingRule) -> Int64 {
        let scaledValue = Double(value) * Double(multiplier) / Double(divisor)
        return Int64(scaledValue.rounded(roundingMode))
    }
}
