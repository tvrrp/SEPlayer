//
//  BoxParser+HEVC.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.07.2025.
//

import CoreMedia

extension BoxParser {
    struct HEVCCodecInfo: Format.InitializationData {
        let codecInfo: CMVideoFormatDescription
        let nalUnitLengthFieldLength: Int

        init(reader: inout ByteBuffer) throws {
            reader.moveReaderIndex(forwardBy: 21)

            let nalUnitHeaderLength = try Int(reader.readInt(as: UInt8.self) & 0x03 + 1)
            let numberOfArrays = try Int(reader.readInt(as: UInt8.self))

            var data: [Data] = []
            for _ in 0..<numberOfArrays {
                reader.moveReaderIndex(forwardBy: 1) // completeness (1), reserved (1), nal_unit_type (6)
                let numberOfNalUnits = try Int(reader.readInt(as: UInt16.self))

                for _ in 0..<numberOfNalUnits {
                    let nalUnitLength = try Int(reader.readInt(as: Int16.self))
                    try data.append(reader.readData(count: nalUnitLength))
                }
            }

            codecInfo = try CMVideoFormatDescription(hevcParameterSets: data, nalUnitHeaderLength: nalUnitHeaderLength)
            nalUnitLengthFieldLength = nalUnitHeaderLength
        }

        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
            codecInfo
        }
    }
}
