//
//  DvbSubtitleReader.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import CoreMedia
import SEPlayerCommon

/// Reads a DVB subtitle stream (ETSI EN 300 743): each PES packet holds one display set, written as one sample to a
/// track per subtitle service the PMT declares.
final class DvbSubtitleReader: ElementaryStreamReader {
    private let subtitleInfos: [TsPayload.DvbSubtitleInfo]
    private var outputs: [TrackOutput] = []
    private var isWritingSample = false
    /// The `data_identifier` and `subtitle_stream_id` bytes still to check at the start of the packet.
    private var bytesToCheck = 0
    private var sampleBytesWritten = 0
    private var sampleTime = CMTime.invalid

    init(subtitleInfos: [TsPayload.DvbSubtitleInfo]) {
        self.subtitleInfos = subtitleInfos
    }

    func seek() {
        isWritingSample = false
        sampleTime = .invalid
    }

    func createTracks(
        output: ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator
    ) throws {
        for info in subtitleInfos {
            idGenerator.generateNewId()
            let trackOutput = try output.track(for: idGenerator.getTrackId(), trackType: .text)
            let initializationData = try BlockBufferReader()
            try initializationData.extend(with: info.initializationData)
            let format = try Format.Builder()
                .setId(idGenerator.getFormatId())
                .setContainerMimeType(.videoMP2T)
                .setSampleMimeType(.applicationDVBSubs)
                .setInitializationData(Format.ByteBufferInitializationData(byteBuffer: [initializationData]))
                .setLanguage(info.language)
                .build()
            SELogger.debug(.transportStream, "DVB subtitle track: \(format)")
            try trackOutput.setFormat(format)
            outputs.append(trackOutput)
        }
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        // A display set starts at a packet aligned to it.
        guard flags.contains(.dataAlignment) else { return }
        isWritingSample = true
        sampleTime = pesTime
        sampleBytesWritten = 0
        bytesToCheck = 2
    }

    func consume(data: inout BlockBufferReader) throws {
        guard isWritingSample else { return }
        // data_identifier 0x20, then subtitle_stream_id 0x00.
        if bytesToCheck == 2, !checkNextByte(&data, expected: 0x20) { return }
        if bytesToCheck == 1, !checkNextByte(&data, expected: 0x00) { return }

        let available = data.readableBytes
        guard available > 0 else { return }
        let slice = try data.readSlice(length: available)
        for output in outputs {
            try output.sampleData(data: slice.blockBuffer)
        }
        sampleBytesWritten += available
    }

    func packetFinished() throws {
        guard isWritingSample else { return }
        isWritingSample = false
        guard sampleTime.isNumeric else { return }
        for output in outputs {
            try output.sampleMetadata(
                time: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: sampleTime, decodeTimeStamp: .invalid),
                flags: .keyframe,
                range: 0 ..< sampleBytesWritten
            )
        }
    }

    /// Reads the next byte: the sample stops being written if it isn't `expected`.
    private func checkNextByte(_ data: inout BlockBufferReader, expected: UInt8) -> Bool {
        guard data.readableBytes > 0 else { return false }
        if (try? data.readInt(as: UInt8.self)) != expected {
            isWritingSample = false
        }
        bytesToCheck -= 1
        return isWritingSample
    }
}
