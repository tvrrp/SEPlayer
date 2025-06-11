//
//  AudioConverter+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//

import Darwin

enum AudioConverterErrors: Error {
    case osStatus(Status?)

    enum Status: OSStatus {
        case formatNotSupported = 1718449215
        case operationNotSupported = 1869627199
        case propertyNotSupported = 1886547824
        case invalidInputSize = 1768846202
        case invalidOutputSize = 1869902714
        case unspecifiedError = 2003329396
        case badPropertySizeError = 561211770
        case requiresPacketDescriptionsError = 561015652
        case inputSampleRateOutOfRange = 560558962
        case outputSampleRateOutOfRange = 560952178
        case hardwareInUse = 1752656245
        case noHardwarePermission = 1885696621

        case custom_nilDataObjectPointer = -1001
        case custom_sampleBufferAudioBufferEmpty = -1002
        case custom_noMoreData = -1003
        case custom_unknown = -1004
    }
}
