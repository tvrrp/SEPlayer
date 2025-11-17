//
//  SpannedDataTest.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import Testing
import ObjectiveC
@testable import SEPlayer

struct SpannedDataTest {
    private let value1 = -1
    private let value2 = -2
    private let value3 = -3

    @Test
    func appendMultipleSpansThenRead() {
        var spannedData = SpannedData<Int>()
        spannedData.appendSpan(startKey: 0, value: value1)
        spannedData.appendSpan(startKey: 2, value: value2)
        spannedData.appendSpan(startKey: 4, value: value3)

        #expect(spannedData.get(0) == value1)
        #expect(spannedData.get(1) == value1)
        #expect(spannedData.get(2) == value2)
        #expect(spannedData.get(3) == value2)
        #expect(spannedData.get(4) == value3)
        #expect(spannedData.get(5) == value3)
    }

    @Test
    func appendEmptySpansDiscarded() {
        var spannedData = SpannedData<Int>()
        spannedData.appendSpan(startKey: 0, value: value1)
        spannedData.appendSpan(startKey: 2, value: value2)
        spannedData.appendSpan(startKey: 2, value: value3)

        #expect(spannedData.get(0) == value1)
        #expect(spannedData.get(1) == value1)
        #expect(spannedData.get(2) == value3)
        #expect(spannedData.get(3) == value3)
    }

    @Test
    func getEndValue() {
        var spannedData = SpannedData<String>()

//        TODO: make getEndValue throwable
//        #expect(throws: Error.self) {
//            spannedData.getEndValue()
//        }

        spannedData.appendSpan(startKey: 0, value: "test 1")
        spannedData.appendSpan(startKey: 2, value: "test 2")
        spannedData.appendSpan(startKey: 4, value: "test 3")

        #expect(spannedData.getEndValue() == "test 3")

        spannedData.discard(from: 2)
        #expect(spannedData.getEndValue() == "test 2")

//        TODO: make getEndValue throwable
//        #expect(throws: Error.self) {
//            spannedData.getEndValue()
//        }
    }

    @Test
    func discardTo() {
        var spannedData = SpannedData<Int>()
        spannedData.appendSpan(startKey: 0, value: value1)
        spannedData.appendSpan(startKey: 2, value: value2)
        spannedData.appendSpan(startKey: 4, value: value3)

        spannedData.discard(to: 2)

        #expect(spannedData.get(0) == value2)
        #expect(spannedData.get(2) == value2)

        spannedData.discard(to: 4)

        #expect(spannedData.get(3) == value3)
        #expect(spannedData.get(4) == value3)
    }

    @Test
    func discardToPrunesEmptySpans() {
        var spannedData = SpannedData<Int>()
        spannedData.appendSpan(startKey: 0, value: value1)
        spannedData.appendSpan(startKey: 2, value: value2)
        spannedData.appendSpan(startKey: 2, value: value3)

        spannedData.discard(to: 2)

        #expect(spannedData.get(0) == value3)
        #expect(spannedData.get(2) == value3)
    }

    @Test
    func discardFromThenAppendKeepsValueIfSpanEndsUpNonEmpty() {
        var spannedData = SpannedData<Int>()
        spannedData.appendSpan(startKey: 0, value: value1)
        spannedData.appendSpan(startKey: 2, value: value2)
        spannedData.appendSpan(startKey: 4, value: value3)

        spannedData.discard(from: 2)
        #expect(spannedData.getEndValue() == value2)

        spannedData.appendSpan(startKey: 3, value: value3)

        #expect(spannedData.get(0) == value1)
        #expect(spannedData.get(1) == value1)
        #expect(spannedData.get(2) == value2)
        #expect(spannedData.get(3) == value3)
    }

    @Test
    func discardFromThenAppendPrunesEmptySpan() {
        var spannedData = SpannedData<Int>()
        spannedData.appendSpan(startKey: 0, value: value1)
        spannedData.appendSpan(startKey: 2, value: value2)

        spannedData.discard(from: 2)
        #expect(spannedData.getEndValue() == value2)

        spannedData.appendSpan(startKey: 2, value: value3)

        #expect(spannedData.get(0) == value1)
        #expect(spannedData.get(1) == value1)
        #expect(spannedData.get(2) == value3)
    }

    @Test
    func clear() {
        var spannedData = SpannedData<Int>()
        spannedData.appendSpan(startKey: 0, value: value1)
        spannedData.appendSpan(startKey: 2, value: value2)

        spannedData.clear()

        spannedData.appendSpan(startKey: 1, value: value3)

        #expect(spannedData.get(0) == value3)
        #expect(spannedData.get(1) == value3)
    }

    @Test
    func isEmpty() {
        var spannedData = SpannedData<String>()
        #expect(spannedData.isEmpty)

        spannedData.appendSpan(startKey: 0, value: "test 1")
        spannedData.appendSpan(startKey: 2, value: "test 2")

        #expect(!spannedData.isEmpty)

        // Discarding from 0 still retains the 'first' span, so collection doesn't end up empty.
        spannedData.discard(from: 0)
        #expect(!spannedData.isEmpty)

        spannedData.appendSpan(startKey: 2, value: "test 2")

        // Discarding to 3 still retains the 'last' span, so collection doesn't end up empty.
        spannedData.discard(to: 3)
        #expect(!spannedData.isEmpty)

        spannedData.clear()
        #expect(spannedData.isEmpty)
    }
}
