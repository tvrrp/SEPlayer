//
//  BoxParser+AVCCodecInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia.CMFormatDescription

extension BoxParser {
    struct AVCCodecInfo {
        let codecInfo: CMVideoFormatDescription

        init(parent: inout ByteBuffer) throws {
            // Skip avvC config version, profile compatibility, level indication
            parent.moveReaderIndex(forwardBy: 4)

            // lengthSizeMinusOne + 1
            // bit(6) reserved, int(2) lengthSizeMinusOne, bit(3) reserved
            let nalUnitHeaderLength = try! Int(parent.readInt(as: Int8.self) & 0x3 + 1)

            func readNalUnit(reader: inout ByteBuffer) throws -> Data {
                let length = try! reader.readInt(as: Int16.self)
                return try! reader.readData(count: Int(length))
            }

            let numbOfSpss = try! parent.readInt(as: Int8.self) & 0x1F
            let sequenceParameterSets = try! (0..<numbOfSpss).map { _ in try! readNalUnit(reader: &parent) }

//            let data = [UInt8](sequenceParameterSets.flatMap { $0 })
//            let tests = try! NalUnitUtil.SpsData(data: data, nalOffset: 0, nalLimit: data.count)

            let numOfPpss = try! parent.readInt(as: Int8.self)
            let pictureParameterSets = try! (0..<numOfPpss).map { _ in try! readNalUnit(reader: &parent) }

            codecInfo = try! CMVideoFormatDescription(
                h264ParameterSets: sequenceParameterSets + pictureParameterSets,
                nalUnitHeaderLength: nalUnitHeaderLength
            )
        }
    }
}
