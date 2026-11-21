//
//  VideoDescriptionPayloads.swift
//  SEPlayer
//

import Foundation

// The payloads of the HDR boxes of ISO/IEC 23001-8 and of the SEI messages of H.265 Annex D, which have the same
// fields, big-endian.

public extension MasteringDisplay {
    /// Reads `mdcv`: the chromaticities of green, blue, red and the white point, then the luminances.
    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 24 else { return nil }
        let fields = BigEndianFields(bytes)
        self.init(
            chromaticities: (0 ..< 8).map { fields.uint16(at: $0 * 2) },
            maximumLuminance: fields.uint32(at: 16),
            minimumLuminance: fields.uint32(at: 20)
        )
    }

    var bytes: Data {
        var data = Data()
        for value in chromaticities.prefix(8) {
            data.appendBigEndian(value)
        }
        data.appendBigEndian(maximumLuminance)
        data.appendBigEndian(minimumLuminance)
        return data
    }
}

public extension ContentLightLevel {
    /// Reads `clli`: the maximum content light level, then the maximum frame-average light level.
    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 4 else { return nil }
        let fields = BigEndianFields(bytes)
        self.init(
            maximumContentLightLevel: Int(fields.uint16(at: 0)),
            maximumFrameAverageLightLevel: Int(fields.uint16(at: 2))
        )
    }

    var bytes: Data {
        var data = Data()
        data.appendBigEndian(UInt16(clamping: maximumContentLightLevel))
        data.appendBigEndian(UInt16(clamping: maximumFrameAverageLightLevel))
        return data
    }
}

public extension AmbientViewingEnvironment {
    /// Reads `amve`: the illuminance, then the chromaticity of the light.
    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 8 else { return nil }
        let fields = BigEndianFields(bytes)
        self.init(illuminance: fields.uint32(at: 0), lightX: fields.uint16(at: 4), lightY: fields.uint16(at: 6))
    }

    var bytes: Data {
        var data = Data()
        data.appendBigEndian(illuminance)
        data.appendBigEndian(lightX)
        data.appendBigEndian(lightY)
        return data
    }
}

public extension ContentColorVolume {
    /// Reads `cclv`: the cancel and persistence flags, which values follow, then the values.
    init?(bytes: some Collection<UInt8>) {
        guard let flags = bytes.first else { return nil }
        let fields = BigEndianFields(bytes)
        self.init(isCanceled: flags & 0x80 != 0)
        guard !isCanceled else { return }
        persists = flags & 0x40 != 0
        var offset = 1
        func next() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return fields.uint32(at: offset)
        }
        if flags & 0x20 != 0 {
            let values = (0 ..< 6).compactMap { _ in next().map { Int32(bitPattern: $0) } }
            guard values.count == 6 else { return nil }
            primaries = values
        }
        if flags & 0x10 != 0 {
            guard let value = next() else { return nil }
            minimumLuminance = value
        }
        if flags & 0x08 != 0 {
            guard let value = next() else { return nil }
            maximumLuminance = value
        }
        if flags & 0x04 != 0 {
            guard let value = next() else { return nil }
            averageLuminance = value
        }
    }

    var bytes: Data {
        guard !isCanceled else { return Data([0x80]) }
        var flags: UInt8 = persists ? 0x40 : 0
        if primaries != nil { flags |= 0x20 }
        if minimumLuminance != nil { flags |= 0x10 }
        if maximumLuminance != nil { flags |= 0x08 }
        if averageLuminance != nil { flags |= 0x04 }
        var data = Data([flags])
        for value in primaries ?? [] {
            data.appendBigEndian(UInt32(bitPattern: value))
        }
        for value in [minimumLuminance, maximumLuminance, averageLuminance].compactMap(\.self) {
            data.appendBigEndian(value)
        }
        return data
    }
}

/// Big-endian fields of bytes where they are, by their offset.
private struct BigEndianFields<Bytes: Collection<UInt8>> {
    let bytes: Bytes

    init(_ bytes: Bytes) {
        self.bytes = bytes
    }

    func uint16(at offset: Int) -> UInt16 {
        UInt16(byte(offset)) << 8 | UInt16(byte(offset + 1))
    }

    func uint32(at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 << 8 | UInt32(byte(offset + $1)) }
    }

    private func byte(_ offset: Int) -> UInt8 {
        bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
    }
}

extension Data {
    mutating func appendBigEndian(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
