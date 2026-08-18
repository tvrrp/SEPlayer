//
//  SeiReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

import CoreMedia
import SEPlayerCommon

final class SeiReader {
    let closedCaptionFormats: [Format]
    let containerMimeType: MimeTypes
    let reorderingBufferQueue: ReorderingBufferQueue
    var outputs: [TrackOutput]

    init(closedCaptionFormats: [Format], containerMimeType: MimeTypes) {
        self.closedCaptionFormats = closedCaptionFormats
        self.containerMimeType = containerMimeType
        reorderingBufferQueue = ReorderingBufferQueue()
        outputs = []
        outputs.reserveCapacity(closedCaptionFormats.count)
    }

    func createTracks(
        extractorOutput: ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator,
        _ isolation: isolated any Actor
    ) async throws {
        for _ in 0..<outputs.capacity {
            idGenerator.generateNewId()
            let output = try extractorOutput.track(for: idGenerator.getTrackId(), trackType: .text)
            let channelFormat = closedCaptionFormats[0]
            let channelMimeType = channelFormat.sampleMimeType

            // TODO: check if mimeType is CEA608 or CEA708
            let formatId = try channelFormat.id ?? idGenerator.getFormatId()
            try await output.setFormat(
                Format.Builder()
                    .setId(formatId)
                    .setContainerMimeType(containerMimeType)
                    .setSampleMimeType(channelMimeType)
                    // TODO: .setSelectionFlags(channelFormat.selectionFlags)
                    .setLanguage(channelFormat.language)
                    // TODO: .setAccessibilityChannel(channelFormat.accessibilityChannel)
                    .setInitializationData(channelFormat.initializationData)
                    .build()
                ,
                isolation: output.isolation
            )

            outputs.append(output)
        }
    }

    func setReorderingQueueSize(_ reorderingQueueSize: Int) throws {
        try reorderingBufferQueue.setMaxSize(reorderingQueueSize)
    }

    func consume(pesTime: CMTime, seiBuffer: inout BlockBufferReader) throws {
        try reorderingBufferQueue.add(presentationTime: pesTime, buffer: &seiBuffer)
    }

    func flush() throws {
        try reorderingBufferQueue.flush()
    }

    func clear() {
        reorderingBufferQueue.clear()
    }
}

extension SeiReader: ReorderingBufferQueue.OutputConsumer {
    func consume(presentationTime: CMTime, buffer: inout BlockBufferReader) throws {
        try CeaUtil.consume(
            presentationTime: presentationTime,
            seiBuffer: &buffer,
            outputs: outputs
        )
    }
}
