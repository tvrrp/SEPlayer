//
//  UserDataReader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Writes the closed captions of the user data of MPEG video (ATSC A/53 `GA94` caption data) to text tracks.
final class UserDataReader {
    private let closedCaptionFormats: [TextFormat]
    private let containerMimeType: MimeTypes
    private let reorderingBufferQueue = ReorderingBufferQueue()

    private var outputs: [TrackOutput] = []
    /// Caption data in presentation order, waiting to be written.
    private var pendingCcData: [CeaUtil.CcData] = []

    init(closedCaptionFormats: [TextFormat], containerMimeType: MimeTypes) throws {
        self.closedCaptionFormats = closedCaptionFormats
        self.containerMimeType = containerMimeType
        reorderingBufferQueue.setOutputConsumer(self)
        // MPEG video reorders up to two B pictures.
        try reorderingBufferQueue.setMaxSize(3)
    }

    func createTracks(extractorOutput: ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        for channelFormat in closedCaptionFormats {
            idGenerator.generateNewId()
            let output = try extractorOutput.track(for: idGenerator.getTrackId(), trackType: .text)
            let formatId = try idGenerator.getFormatId()
            let format = TextFormat {
                $0.id = formatId
                $0.containerMimeType = containerMimeType
                $0.codec = channelFormat.codec
                $0.selectionFlags = channelFormat.selectionFlags
                $0.language = channelFormat.language
            }
            try output.setFormat(AnyFormat(format))
            outputs.append(output)
        }
    }

    /// Reads a user data unit, from its start code, without emulation prevention bytes.
    func consume(pesTime: CMTime, userData: inout BlockBufferReader) throws {
        guard !outputs.isEmpty, userData.readableBytes >= 9 else { return }
        let startCode = try userData.readInt(as: UInt32.self)
        let identifier = try userData.readInt(as: UInt32.self)
        let typeCode = try Int(userData.readInt(as: UInt8.self))
        guard startCode == Self.userDataStartCode,
              identifier == CeaUtil.userIdentifierGA94,
              typeCode == CeaUtil.userDataTypeCodeMpegCc else {
            return
        }
        try reorderingBufferQueue.add(presentationTime: pesTime, buffer: &userData)
        try writePendingSamples()
    }

    func flush() throws {
        try reorderingBufferQueue.flush()
        try writePendingSamples()
    }

    func clear() {
        reorderingBufferQueue.clear()
        pendingCcData.removeAll()
    }

    private func writePendingSamples() throws {
        guard !pendingCcData.isEmpty else { return }
        let ccData = pendingCcData
        pendingCcData.removeAll(keepingCapacity: true)
        for data in ccData where data.presentationTime.isNumeric {
            for output in outputs {
                try output.sampleData(data: data.packets.blockBuffer)
                try output.sampleMetadata(
                    time: CMSampleTimingInfo(
                        duration: .invalid,
                        presentationTimeStamp: data.presentationTime,
                        decodeTimeStamp: .invalid
                    ),
                    flags: .keyframe,
                    range: 0 ..< data.packets.readableBytes
                )
            }
        }
    }
}

extension UserDataReader: ReorderingBufferQueue.OutputConsumer {
    func consume(presentationTime: CMTime, buffer: inout BlockBufferReader) throws {
        if let ccData = try CeaUtil.ccData(presentationTime: presentationTime, buffer: &buffer, limit: buffer.capacity) {
            pendingCcData.append(ccData)
        }
    }
}

private extension UserDataReader {
    static let userDataStartCode: UInt32 = 0x0000_01B2
}
