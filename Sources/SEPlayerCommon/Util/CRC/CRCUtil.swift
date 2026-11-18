//
//  CrcUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.08.2026.
//
import Foundation

public class CrcUtil {
    /// Compute CRC-8 for manual set of parameters
    @_specialize(where T == BlockBufferView)
    public static func computeCrc8<T: RandomAccessCollection<UInt8>>(
        _ data: T,
        initialCrc: UInt8 = 0x00,
        polynom: UInt8 = 0x07,
        xor: UInt8 = 0x00,
        refIn: Bool = false,
        refOut: Bool = false
    ) -> UInt8 {
        var crc: UInt8 = initialCrc

        for byte in data {
            if refIn {
                crc = UInt8(DataHelper.reverseBits(byte)) ^ crc
            } else {
                crc = byte ^ crc
            }

            for _ in 0 ..< 8 {
                let check = crc & 0x80
                crc = crc << 1

                if check != 0 {
                    crc = crc ^ polynom
                }
            }
        }

        if refOut {
            crc = DataHelper.reverseBits(crc)
        }

        return crc ^ xor
    }

    /// Compute CRC-16 for manual set of parameters
    @_specialize(where T == BlockBufferView)
    public static func computeCrc16<T: RandomAccessCollection<UInt8>>(
        _ data: T,
        initialCrc: UInt16 = 0xFFFF,
        polynom: UInt16 = 0x1021,
        xor: UInt16 = 0x0000,
        refIn: Bool = false,
        refOut: Bool = false
    ) -> UInt16 {
        var crc: UInt16 = initialCrc

        for byte in data {
            if refIn {
                crc = (UInt16(DataHelper.reverseBits(byte)) << 8) ^ crc
            } else {
                crc = (UInt16(byte) << 8) ^ crc
            }

            for _ in 0 ..< 8 {
                let check = crc & 0x8000
                crc = crc << 1

                if check != 0 {
                    crc = crc ^ polynom
                }
            }
        }

        if refOut {
            crc = DataHelper.reverseBits(crc)
        }

        return crc ^ xor
    }

    /// Compute CRC-32 for manual set of parameters
    @_specialize(where T == BlockBufferView)
    public static func computeCrc32<T: RandomAccessCollection<UInt8>>(
        _ data: T,
        initialCrc: UInt32 = 0xFFFFFFFF,
        polynom: UInt32 = 0x04C11DB7,
        xor: UInt32 = 0xFFFFFFFF,
        refIn: Bool = true,
        refOut: Bool = true
    ) -> UInt32 {
        var crc: UInt32 = initialCrc

        for byte in data {
            if refIn {
                crc = (UInt32(DataHelper.reverseBits(byte)) << 24) ^ crc
            } else {
                crc = (UInt32(byte) << 24) ^ crc
            }

            for _ in 0 ..< 8 {
                let check = crc & 0x80000000
                crc = crc << 1

                if check != 0 {
                    crc = crc ^ polynom
                }
            }
        }

        if refOut {
            crc = DataHelper.reverseBits(crc)
        }

        return crc ^ xor
    }

    /// Compute CRC-8 for mode preset
    @_specialize(where T == BlockBufferView)
    public static func computeCrc8<T: RandomAccessCollection<UInt8>>(_ data: T, mode: CRC8_TYPE = .defaultCrc) -> UInt8 {
        let config = ConfigHelper.getCrc8VariablesByMode(mode: mode)

        return computeCrc8(
            data,
            initialCrc: config.initialCrc,
            polynom: config.polynom,
            xor: config.xor,
            refIn: config.refIn,
            refOut: config.refOut
        )
    }

    /// Compute CRC-16 for mode preset
    @_specialize(where T == BlockBufferView)
    public static func computeCrc16<T: RandomAccessCollection<UInt8>>(_ data: T, mode: CRC16_TYPE = .ccittFalse) -> UInt16 {
        let config = ConfigHelper.getCrc16VariablesByMode(mode: mode)

        return computeCrc16(
            data,
            initialCrc: config.initialCrc,
            polynom: config.polynom,
            xor: config.xor,
            refIn: config.refIn,
            refOut: config.refOut
        )
    }

    /// Compute CRC-32 for mode preset
    @_specialize(where T == BlockBufferView)
    public static func computeCrc32<T: RandomAccessCollection<UInt8>>(_ data: T, mode: CRC32_TYPE = .defaultCrc) -> UInt32 {
        let config = ConfigHelper.getCrc32VariablesByMode(mode: mode)

        return computeCrc32(
            data,
            initialCrc: config.initialCrc,
            polynom: config.polynom,
            xor: config.xor,
            refIn: config.refIn,
            refOut: config.refOut
        )
    }
}
