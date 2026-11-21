//
//  SeiReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

import CoreMedia
import SEPlayerCommon

/// Writes the closed captions of SEI messages to text tracks, one per caption format, in presentation order.
final class SeiReader {
    let closedCaptionFormats: [TextFormat]
    let containerMimeType: MimeTypes
    let reorderingBufferQueue: ReorderingBufferQueue
    var outputs: [TrackOutput]

    /// Caption data in presentation order, waiting to be written.
    private var pendingCcData: [CeaUtil.CcData] = []

    init(closedCaptionFormats: [TextFormat], containerMimeType: MimeTypes) {
        self.closedCaptionFormats = closedCaptionFormats
        self.containerMimeType = containerMimeType
        reorderingBufferQueue = ReorderingBufferQueue()
        outputs = []
        outputs.reserveCapacity(closedCaptionFormats.count)
        reorderingBufferQueue.setOutputConsumer(self)
    }

    func createTracks(
        extractorOutput: ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator
    ) throws {
        for channelFormat in closedCaptionFormats {
            idGenerator.generateNewId()
            let output = try extractorOutput.track(for: idGenerator.getTrackId(), trackType: .text)
            let formatId = try channelFormat.id ?? idGenerator.getFormatId()
            let format = TextFormat {
                $0.id = formatId
                $0.label = channelFormat.label
                $0.containerMimeType = containerMimeType
                $0.codec = channelFormat.codec
                $0.selectionFlags = channelFormat.selectionFlags
                $0.roleFlags = channelFormat.roleFlags
                $0.language = channelFormat.language
            }
            SELogger.debug(.transportStream, "Caption track \(formatId): \(format)")
            try output.setFormat(AnyFormat(format))
            outputs.append(output)
        }
    }

    func setReorderingQueueSize(_ reorderingQueueSize: Int) throws {
        try reorderingBufferQueue.setMaxSize(reorderingQueueSize)
    }

    func consume(pesTime: CMTime, seiBuffer: inout BlockBufferReader) throws {
        guard !outputs.isEmpty else { return }
        try reorderingBufferQueue.add(presentationTime: pesTime, buffer: &seiBuffer)
    }

    func flush() throws {
        try reorderingBufferQueue.flush()
    }

    func clear() {
        reorderingBufferQueue.clear()
        pendingCcData.removeAll()
    }

    /// Writes the caption data that left the reordering queue.
    func writePendingSamples() throws {
        guard !pendingCcData.isEmpty else { return }
        let ccData = pendingCcData
        pendingCcData.removeAll(keepingCapacity: true)
        for data in ccData where data.presentationTime.isNumeric {
            for output in outputs {
                try output.sampleData(data: data.packets.blockBuffer)
                try output.sampleMetadata(
                    time: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: data.presentationTime, decodeTimeStamp: .invalid),
                    flags: .keyframe,
                    range: 0 ..< data.packets.readableBytes
                )
            }
        }
    }
}

extension SeiReader: ReorderingBufferQueue.OutputConsumer {
    func consume(presentationTime: CMTime, buffer: inout BlockBufferReader) throws {
        pendingCcData += try CeaUtil.ccData(presentationTime: presentationTime, seiBuffer: &buffer)
    }
}
