//
//  Prewarmer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 09.07.2025.
//

import VideoToolbox

final class Prewarmer {
    static let shared = Prewarmer()
    private static var needsPrewarm = false

    private let esDescriptorAacAudio = Data([
        0x03, 0x80, 0x80, 0x80, 0x30, 0x00, 0x02, 0x00,
        0x04, 0x80, 0x80, 0x80, 0x22, 0x40, 0x15, 0x00,
        0x00, 0x00, 0x00, 0x01, 0xF4, 0x47, 0x00, 0x01,
        0xF4, 0x47, 0x05, 0x80, 0x80, 0x80, 0x10, 0x12,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x80,
        0x80, 0x80, 0x01, 0x02
    ])

    private let avcPpsData = Data([0x68, 0xEB, 0x8F, 0x2C])
    private let avcSpsData = Data([
        0x67, 0x64, 0x00, 0x28, 0xAC, 0xD1, 0x00, 0x44,
        0x03, 0xC7, 0x97, 0xC0, 0x5A, 0x80, 0x80, 0x80,
        0xA0, 0x00, 0x00, 0x7D, 0x20, 0x00, 0x17, 0x70,
        0x01, 0xE3, 0x06, 0x22, 0x40
    ])

    func prewarm() {
        guard Self.needsPrewarm else { return }

        Self.needsPrewarm = false
        prewarmAudio()
        prewarmVideo()
    }

    private func prewarmAudio() {
        DispatchQueue.global(qos: .background).async { [self] in
            guard let codecInfo = try? BoxParser.ESDescriptor(esdt: esDescriptorAacAudio).codecInfo else {
                return
            }

            let format = Format.Builder()
                .setInitializationData(PrewarmerInitializationData(formatDescription: codecInfo))
                .build()

            _ = try? AudioConverterDecoder.supportsFormat(format)
        }
    }

    private func prewarmVideo() {
        DispatchQueue.global(qos: .background).async { [self] in
            guard let format = try? CMFormatDescription(h264ParameterSets: [avcSpsData, avcPpsData], nalUnitHeaderLength: 4) else {
                return
            }

            var decompressionSession: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: nil,
                formatDescription: format,
                decoderSpecification: nil,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &decompressionSession
            )

            if status == noErr, let session = decompressionSession {
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
            }
        }
    }
}

private struct PrewarmerInitializationData: Format.InitializationData {
    let formatDescription: CMFormatDescription

    func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
        return formatDescription
    }
}
