//
//  AccumulatedComparison.swift
//  SEPlayer
//
//  Created by tvrrp on 19.02.2026.
//

import CoreFoundation

extension Array {
    func maxElement(_ comparator: (_ lhs: Element, _ rhs: Element) -> CFComparisonResult) -> Element? {
        var iterator = self.makeIterator()
        guard var candidate = iterator.next() else {
            return nil
        }

        while let next = iterator.next() {
            if comparator(next, candidate) == .compareGreaterThan {
                candidate = next
            }
        }

        return candidate
    }
}

enum AccumulatedComparison {
    case active
    case decided(CFComparisonResult)

    static func start() -> AccumulatedComparison {
        return .active
    }

    @discardableResult
    func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> AccumulatedComparison {
        guard case .active = self else { return self }

        if lhs == rhs { return classify(.compareEqualTo) }
        guard let lhs else { return classify(.compareLessThan) }
        guard let rhs else { return classify(.compareGreaterThan) }

        return lhs < rhs ? classify(.compareLessThan) : classify(.compareGreaterThan)
    }

    @discardableResult
    func compare<T>(_ lhs: T?, _ rhs: T?, _ comparator: (_ lhs: T, _ rhs: T) -> CFComparisonResult) -> AccumulatedComparison {
        guard case .active = self else { return self }

        guard let lhs, let rhs else {
            return classify(.compareEqualTo)
        }
        return classify(comparator(lhs, rhs))
    }

    @discardableResult
    func compareTrueFirst(_ lhs: Bool, _ rhs: Bool) -> AccumulatedComparison {
        guard case .active = self else { return self }

        return compareFalseFirst(rhs, lhs)
    }

    @discardableResult
    func compareFalseFirst(_ lhs: Bool, _ rhs: Bool) -> AccumulatedComparison {
        guard case .active = self else { return self }

        return classify((lhs == rhs) ? .compareEqualTo : (lhs ? .compareGreaterThan : .compareLessThan))
    }

    func result() -> CFComparisonResult { .compareEqualTo }

    private func classify(_ result: CFComparisonResult) -> AccumulatedComparison {
        switch result {
        case .compareLessThan, .compareGreaterThan:
            .decided(result)
        case .compareEqualTo:
            .active
        @unknown default:
            .active
        }
    }
}
