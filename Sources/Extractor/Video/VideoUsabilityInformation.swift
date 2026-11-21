//
//  VideoUsabilityInformation.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

/// The fields of the video usability information that describe pictures, as H.264 and H.265 Annex E have them up to
/// the chroma location. Each is `nil` when its presence flag is off.
struct VideoUsabilityInformation: Hashable {
    struct AspectRatio: Hashable {
        /// aspect_ratio_idc: 255 for an explicit ratio, 1 to 16 for the ratios of Table E-1, others unspecified.
        let indicator: Int
        let sarWidth: Int
        let sarHeight: Int
    }

    struct ColourDescription: Hashable {
        let colourPrimaries: Int
        let transferCharacteristics: Int
        let matrixCoefficients: Int
    }

    let aspectRatio: AspectRatio?
    /// video_full_range_flag, with video_signal_type_present_flag.
    let videoFullRange: Bool?
    let colourDescription: ColourDescription?
    /// chroma_sample_loc_type_top_field and chroma_sample_loc_type_bottom_field.
    let chromaSampleLocation: (topField: Int, bottomField: Int)?
    /// field_seq_flag of H.265: the pictures are fields.
    let fieldSequence: Bool

    static let extendedSampleAspectRatio = 255

    /// Reads from aspect_ratio_info_present_flag on; for H.265 up to field_seq_flag.
    init<T>(reading data: inout ParsableNalUnitBitArray<T>, isH265: Bool) throws {
        if try data.readBit() { // aspect_ratio_info_present_flag
            let indicator = try data.readBits(8)
            if indicator == Self.extendedSampleAspectRatio {
                aspectRatio = try AspectRatio(indicator: indicator, sarWidth: data.readBits(16), sarHeight: data.readBits(16))
            } else {
                aspectRatio = AspectRatio(indicator: indicator, sarWidth: 0, sarHeight: 0)
            }
        } else {
            aspectRatio = nil
        }

        if try data.readBit() { // overscan_info_present_flag
            try data.skipBit() // overscan_appropriate_flag
        }

        if try data.readBit() { // video_signal_type_present_flag
            try data.skipBits(3) // video_format
            videoFullRange = try data.readBit()
            if try data.readBit() { // colour_description_present_flag
                colourDescription = try ColourDescription(
                    colourPrimaries: data.readBits(8),
                    transferCharacteristics: data.readBits(8),
                    matrixCoefficients: data.readBits(8)
                )
            } else {
                colourDescription = nil
            }
        } else {
            videoFullRange = nil
            colourDescription = nil
        }

        if try data.readBit() { // chroma_loc_info_present_flag
            chromaSampleLocation = try (data.readUnsignedExpGolombCodedInt(), data.readUnsignedExpGolombCodedInt())
        } else {
            chromaSampleLocation = nil
        }

        if isH265 {
            try data.skipBit() // neutral_chroma_indication_flag
            fieldSequence = try data.readBit()
        } else {
            fieldSequence = false
        }
    }

    /// The sample aspect ratio, as a horizontal and a vertical spacing: an explicit one, one of Table E-1, or `nil`
    /// with an unspecified indicator.
    var sampleAspectRatio: (horizontal: Int, vertical: Int)? {
        guard let aspectRatio else { return nil }
        if aspectRatio.indicator == Self.extendedSampleAspectRatio {
            return (aspectRatio.sarWidth, aspectRatio.sarHeight)
        }
        guard (1 ... 16).contains(aspectRatio.indicator) else { return nil }
        return Self.sampleAspectRatios[aspectRatio.indicator - 1]
    }

    /// Table E-1 of H.264 and H.265, from indicator 1.
    private static let sampleAspectRatios: [(Int, Int)] = [
        (1, 1), (12, 11), (10, 11), (16, 11), (40, 33), (24, 11), (20, 11), (32, 11),
        (80, 33), (18, 11), (15, 11), (64, 33), (160, 99), (4, 3), (3, 2), (2, 1),
    ]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.aspectRatio == rhs.aspectRatio && lhs.videoFullRange == rhs.videoFullRange
            && lhs.colourDescription == rhs.colourDescription && lhs.fieldSequence == rhs.fieldSequence
            && lhs.chromaSampleLocation?.topField == rhs.chromaSampleLocation?.topField
            && lhs.chromaSampleLocation?.bottomField == rhs.chromaSampleLocation?.bottomField
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(aspectRatio)
        hasher.combine(colourDescription)
    }
}
