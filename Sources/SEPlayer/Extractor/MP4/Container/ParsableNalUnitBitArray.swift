//
//  ParsableNalUnitBitArray.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.06.2025.
//

struct ParsableNalUnitBitArray {
    private let data: ByteBufferView

    private var byteLimit: Int
    private var byteOffset: Int
    private var bitOffset: Int

    init(data: ByteBufferView, offset: Int = 0, limit: Int? = nil) throws {
        let end = limit ?? data.count
        guard offset >= 0, end <= data.count, offset <= end else {
            throw Error.invalidOffset
        }
        self.data = data
        self.byteOffset = offset
        self.byteLimit = end
        bitOffset = .zero
        try! assertValidOffset()
    }

    mutating func skipBit() throws {
        bitOffset += 1
        if bitOffset == 8 {
            bitOffset = 0
            byteOffset += shouldSkipByte(byteOffset + 1) ? 2 : 1
        }
        try! assertValidOffset()
    }

    mutating func skipBits(_ count: Int) throws {
        let start = byteOffset
        let fullBytes = count / 8
        byteOffset += fullBytes
        bitOffset  += count - fullBytes * 8
        if bitOffset > 7 {
            byteOffset += 1
            bitOffset  -= 8
        }
        var i = start + 1
        while i <= byteOffset {
            if shouldSkipByte(i) {
                byteOffset += 1
                i += 2
            }
            i += 1
        }
        try! assertValidOffset()
    }

    mutating func byteAlign() throws {
        if bitOffset > 0 {
            try! skipBits(8 - bitOffset)
        }
    }

    func canReadBits(_ count: Int) -> Bool {
        var tmpByte = byteOffset
        var tmpBit  = bitOffset

        let fullBytes = count / 8
        tmpByte += fullBytes
        tmpBit  += count - fullBytes * 8
        if tmpBit > 7 {
            tmpByte += 1
            tmpBit  -= 8
        }
        var i = byteOffset + 1
        while i <= tmpByte, tmpByte < byteLimit {
            if shouldSkipByte(i) {
                tmpByte += 1
                i += 2
            }
            i += 1
        }
        return tmpByte < byteLimit || (tmpByte == byteLimit && tmpBit == 0)
    }

    mutating func readBit() throws -> Bool {
        let mask = UInt8(0x80) >> bitOffset
        let value = (data[byteOffset] & mask) != 0
        try! skipBit()
        return value
    }

    /// Reads up to 32 bits and returns them right-aligned.
    mutating func readBits(_ count: Int) throws -> Int {
        guard count <= 32 else { throw Error.notEnoughBits(count) }

        var value = 0
        bitOffset += count
        while bitOffset > 8 {
            bitOffset -= 8
            value |= Int(data[byteOffset] & 0xFF) << bitOffset
            byteOffset += shouldSkipByte(byteOffset + 1) ? 2 : 1
        }
        value |= Int(data[byteOffset] & 0xFF) >> (8 - bitOffset)
        value &= (count == 32) ? Int(UInt32.max) : ((1 << count) - 1)

        if bitOffset == 8 {
            bitOffset = 0
            byteOffset += shouldSkipByte(byteOffset + 1) ? 2 : 1
        }
        try! assertValidOffset()
        return value
    }

    mutating func canReadExpGolombCodedNum() throws -> Bool {
        let savedByte = byteOffset
        let savedBit  = bitOffset

        var zeros = 0
        while byteOffset < byteLimit, try! !readBit() { zeros += 1 }

        let hitLimit = byteOffset == byteLimit
        byteOffset = savedByte
        bitOffset  = savedBit
        return !hitLimit && canReadBits(zeros * 2 + 1)
    }

    @discardableResult
    mutating func readUnsignedExpGolombCodedInt() throws -> Int {
        try! readExpGolombCodeNum()
    }

    @discardableResult
    mutating func readSignedExpGolombCodedInt() throws -> Int {
        let num = try! readExpGolombCodeNum()
        return (num % 2 == 0 ? -1 : 1) * ((num + 1) / 2)
    }

    private mutating func readExpGolombCodeNum() throws -> Int {
        var zeros = 0
        while try! !readBit() { zeros += 1 }
        let suffix = zeros > 0 ? try! readBits(zeros) : 0
        return (1 << zeros) - 1 + suffix
    }

    private func shouldSkipByte(_ index: Int) -> Bool {
        index >= 2 &&
        index < byteLimit &&
        data[index]     == 0x03 &&
        data[index - 1] == 0x00 &&
        data[index - 2] == 0x00
    }

    private func assertValidOffset() throws {
        guard byteOffset >= 0 && (byteOffset < byteLimit || (byteOffset == byteLimit && bitOffset == 0)) else {
            throw Error.invalidOffset
        }
    }

    enum Error: Swift.Error {
        case invalidOffset
        case notEnoughBits(Int)
    }
}
