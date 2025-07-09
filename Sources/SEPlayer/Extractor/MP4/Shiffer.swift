//
//  Shiffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.06.2025.
//

struct Sniffer {
    func sniffFragmented(input: ExtractorInput) throws -> SniffFailure? {
        try sniffInternal(input: input, fragmented: true, acceptHeic: false)
    }

    func sniffUnfragmented(input: ExtractorInput, acceptHeic: Bool) throws -> SniffFailure? {
        try sniffInternal(input: input, fragmented: false, acceptHeic: acceptHeic)
    }

    private func sniffInternal(input: ExtractorInput, fragmented: Bool, acceptHeic: Bool) throws -> SniffFailure? {
        let inputLength = input.getLength()
        var bytesToSearch: Int = if let inputLength {
            min(inputLength, .searchLenght)
        } else {
            .searchLenght
        }

        var buffer = ByteBuffer()
        var bytesSearched = 0
        var foundGoodFileType = false
        var isFragmented = false

        while bytesSearched < bytesToSearch {
            var headerSize = MP4Box.headerSize
            buffer.clear(minimumCapacity: headerSize)
            let success = try input.peekFully(to: &buffer, offset: 0, length: headerSize, allowEndOfInput: true)
            if !success { break }

            var atomSize = try UInt64(buffer.readInt(as: UInt32.self))
            let atomType = try buffer.readInt(as: UInt32.self)
            if Int(atomSize) == MP4Box.definesLargeSize {
                headerSize = MP4Box.longHeaderSize
                try input.peekFully(to: &buffer, offset: MP4Box.headerSize, length: MP4Box.longHeaderSize - MP4Box.headerSize)
                atomSize = try buffer.readInt(as: UInt64.self)
            } else if atomSize == MP4Box.extendsToEndSize {
                if let fileEndPosition = input.getLength() {
                    atomSize = UInt64(fileEndPosition - input.getPeekPosition() + headerSize)
                }
            }

            if atomSize < headerSize {
                return AtomSizeTooSmallSniffFailure(
                    atomType: .init(rawValue: atomType),
                    atomSize: Int(atomSize),
                    minimumHeaderSize: headerSize
                )
            }
            bytesSearched += headerSize

            if atomType == MP4Box.BoxType.moov.rawValue {
                // We have seen the moov atom. We increase the search size to make sure we don't miss an
                // mvex atom because the moov's size exceeds the search length.
                bytesToSearch += Int(atomSize)
                if let inputLength, bytesToSearch > inputLength {
                    bytesToSearch = inputLength
                }
                // Check for an mvex atom inside the moov atom to identify whether the file is fragmented.
                continue
            }

            if atomType == MP4Box.BoxType.moov.rawValue || atomType == MP4Box.BoxType.mvex.rawValue {
                // The movie is fragmented. Stop searching as we must have read any ftyp atom already.
                isFragmented = true
                break
            }

            if atomType == MP4Box.BoxType.mdat.rawValue {
                // The original QuickTime specification did not require files to begin with the ftyp atom.
                // See https://developer.apple.com/standards/qtff-2001.pdf.
                foundGoodFileType = true
            }

            if bytesSearched + Int(atomSize) - headerSize >= bytesToSearch {
                // Stop searching as peeking this atom would exceed the search limit.
                break
            }

            let atomDataSize = Int(atomSize) - headerSize
            bytesSearched += atomDataSize

            if atomType == MP4Box.BoxType.ftyp.rawValue {
                guard atomSize > 8 else {
                    return AtomSizeTooSmallSniffFailure(
                        atomType: .ftyp,
                        atomSize: Int(atomSize),
                        minimumHeaderSize: 8
                    )
                }

                buffer.clear(minimumCapacity: atomDataSize)
                try input.peekFully(to: &buffer, offset: 0, length: atomDataSize)
                let majorBrand = try buffer.readInt(as: UInt32.self)
                if isCompatibleBrand(majorBrand, acceptHeic: acceptHeic) {
                    foundGoodFileType = true
                }
                buffer.moveReaderIndex(forwardBy: 4) // Skip the minorVersion
                let compatibleBrandsCount = buffer.readableBytes / 4

                var compatibleBrands = [UInt32]()
                if !foundGoodFileType, compatibleBrandsCount > 0 {
                    for _ in 0..<compatibleBrandsCount {
                        let compatibleBrand = try buffer.readInt(as: UInt32.self)
                        compatibleBrands.append(compatibleBrand)
                        if isCompatibleBrand(compatibleBrand, acceptHeic: acceptHeic) {
                            foundGoodFileType = true
                            break
                        }
                    }
                }

                if !foundGoodFileType {
                    return UnsupportedBrandsSniffFailure(
                        majorBrand: majorBrand,
                        compatibleBrands: compatibleBrands
                    )
                }
            } else if atomDataSize != 0 {
                try input.advancePeekPosition(length: atomDataSize)
            }
        }

        if !foundGoodFileType {
            return NoDeclaredBrandSniffFailure()
        } else if fragmented != isFragmented {
            return isFragmented ? IncorrectFragmentationSniffFailure.fileFragmented() : IncorrectFragmentationSniffFailure.fileNotFragmented()
        } else {
            return nil
        }
    }

    private func isCompatibleBrand(_ brand: UInt32, acceptHeic: Bool) -> Bool {
        if brand >> 8 == 0x00336770 {
            // Brand starts with '3gp'.
            return true
        } else if brand == brandHeic, acceptHeic {
            return true
        } else {
            return compatibleBrands.contains(brand)
        }
    }
}

private extension Sniffer {
    var compatibleBrands: [UInt32] {
        [
            0x69736f6d, // isom
            0x69736f32, // iso2
            0x69736f33, // iso3
            0x69736f34, // iso4
            0x69736f35, // iso5
            0x69736f36, // iso6
            0x69736f39, // iso9
            0x61766331, // avc1
            0x68766331, // hvc1
            0x68657631, // hev1
            0x61763031, // av01
            0x6d703431, // mp41
            0x6d703432, // mp42
            0x33673261, // 3g2a
            0x33673262, // 3g2b
            0x33677236, // 3gr6
            0x33677336, // 3gs6
            0x33676536, // 3ge6
            0x33676736, // 3gg6
            0x4d345620, // M4V[space]
            0x4d344120, // M4A[space]
            0x66347620, // f4v[space]
            0x6b646469, // kddi
            0x4d345650, // M4VP
            brandQuickTime, // qt[space][space]
            0x4d534e56, // MSNV, Sony PSP
            0x64627931, // dby1, Dolby Vision
            0x69736d6c, // isml
            0x70696666, // piff
        ]
    }

    var brandQuickTime: UInt32 { 0x71742020 }
    var brandHeic: UInt32 { 0x68656963 }
}

private extension Int {
    static let searchLenght: Int = 4 * 1024
}
