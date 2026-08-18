//
//  TransportStreamTypes.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

public struct TSConstants {
    public static let packetSize: Int = 188
    public static let timestampSearchBytes = TSConstants.packetSize * 600
    public static let syncByte: UInt8 = 0x47
    public static let maxPidPlusOne = 0x2000
    public static let bufferSize = TSConstants.packetSize * 50
    public static let sniffPacketCount = 5
}

public enum TSStreamType: Int {
    case mpa = 0x03;
    case mpaLsf = 0x04;
    case aacAdts = 0x0F;
    case aacLatm = 0x11;
    case ac3 = 0x81;
    case dts = 0x8A;
    case hdmvDts = 0x82;
    case eAc3 = 0x87;
    case ac4 = 0xAC; // DVB/ATSC AC-4 Descriptor
    case h262 = 0x02;
    case h263 = 0x10; // MPEG-4 Part 2 and H.263
    case h264 = 0x1B;
    case h265 = 0x24;
    case mhas = 0x2D;
    case id3 = 0x15;
    case spliceInfo = 0x86;
    case dvbSubs = 0x59;
    case dtsHD = 0x88; // As per ATSC Code Point Registry
    case dtsUHD = 0x8B;

    // Stream types that aren't defined by the MPEG-2 TS specification.
    case dc2H262 = 0x80
    case ait = 0x101
}
