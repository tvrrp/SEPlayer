//
//  ColorSpace.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.06.2025.
//

import CoreMedia.CMFormatDescription

enum ColorSpace: Int {
    case bt709 = 2
    case bt2020 = 3

    init?(isoColorPrimaries: RawValue) {
        switch isoColorPrimaries {
        case 1:
            self = .bt709
        case 4: fallthrough // BT.470M.
        case 5: fallthrough // BT.470BG.
        case 6: fallthrough // SMPTE 170M.
        case 7: // SMPTE 240M.
            // bt607 is not supported
            return nil
        case 9:
            self = .bt2020
        default:
            // Remaining color primaries are either reserved or unspecified.
            return nil
        }
    }
}

extension ColorSpace {
    static let coreMediaName: CFString = kCMFormatDescriptionExtension_ColorPrimaries

    var coreMediaValue: CFString {
        switch self {
        case .bt709:
            kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case .bt2020:
            kCMFormatDescriptionColorPrimaries_ITU_R_2020
        }
    }
}

enum ColorTransfer: Int {
    case linear
    case sdr
    case sRGB
    case gamma22
    case ST2084
    case hlg

    init?(isoTransferCharacteristics: Int) {
        switch isoTransferCharacteristics {
        case 1: fallthrough // BT.709.
        case 6: fallthrough // SMPTE 170M
        case 7: // SMPTE 240M.
            self = .sdr
        case 4:
            self = .gamma22
        case 13:
            self = .sRGB
        case 16:
            self = .ST2084
        case 18:
            self = .hlg
        default:
            return nil
        }
    }

    static let coreMediaName: CFString = kCMFormatDescriptionExtension_TransferFunction

    var coreMediaValue: CFString {
        switch self {
        case .linear:
            kCMFormatDescriptionTransferFunction_Linear
        case .sdr:
            kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case .sRGB:
            kCMFormatDescriptionTransferFunction_sRGB
        case .gamma22:
            kCMFormatDescriptionTransferFunction_UseGamma
        case .ST2084:
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .hlg:
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }
    }
}
