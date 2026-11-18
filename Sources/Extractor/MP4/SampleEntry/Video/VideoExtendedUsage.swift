//
//  VideoExtendedUsage.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import CoreMedia
import SEPlayerCommon

/// Reads the video extended usage box, `vexu`, of stereo and immersive video: which eyes the views hold, the hero
/// eye, the camera baseline and disparity adjustment, the projection and the packing of the views.
///
/// Each box lists the boxes it holds that a reader must understand in a `must` box; those not read here are named
/// by their path. The lens collection of a camera system isn't read here.
enum VideoExtendedUsage {
    enum ReadError: Error {
        /// A box that doesn't fit, or a field of the wrong size: the system refuses the entry too.
        case malformed
        /// A lens collection, whose calibration isn't read here.
        case lensCollection
    }

    /// Adds the extensions of a `vexu` box.
    ///
    /// - Parameter vexu: The payload of the box, its indices starting at 0.
    static func addExtensions(vexu: BlockBufferReader, to extensions: inout SampleDescriptionExtensions) throws(ReadError) {
        var reader = Reader(extensions: extensions)
        try reader.readContainer(vexu, path: [.vexu])
        if !reader.unrecognizedPaths.isEmpty {
            let paths = reader.unrecognizedPaths.map { path in
                path.map { SampleDescriptionExtensions.number(Int32(bitPattern: $0)) }
            }
            reader.extensions.addFirst(paths, for: SampleDescriptionExtensionKey.requiredButUnrecognizedFormatAtoms)
        }
        extensions = reader.extensions
    }

    /// The boxes each box holds that are read here.
    private static func childTypes(of container: MP4Box.BoxType) -> Set<MP4Box.BoxType> {
        switch container {
        case .vexu: [.must, .eyes, .cmra, .proj, .pack, .lnsc]
        case .eyes: [.must, .stri, .hero, .cams, .cmfy]
        case .cams: [.must, .blin]
        case .cmfy: [.must, .dadj]
        case .cmra: [.must, .tiny]
        case .proj: [.must, .prji]
        case .pack: [.must, .pkin]
        default: []
        }
    }

    private struct Reader {
        var extensions: SampleDescriptionExtensions
        /// The paths, from `vexu` on, of the boxes a `must` box requires that aren't read here.
        var unrecognizedPaths: [[UInt32]] = []

        mutating func readContainer(_ payload: BlockBufferReader, path: [MP4Box.BoxType]) throws(ReadError) {
            guard let container = path.last else { return }
            let readable = VideoExtendedUsage.childTypes(of: container)
            var readTypes: Set<UInt32> = []
            var requiredTypes: [UInt32] = []

            for (rawType, child) in try children(of: payload) {
                guard let type = MP4Box.BoxType(rawValue: rawType), readable.contains(type) else {
                    continue
                }
                switch type {
                case .must:
                    // The last list of required boxes wins.
                    requiredTypes = try requiredBoxTypes(child)
                case .lnsc:
                    throw .lensCollection
                case .eyes,
                     .cams,
                     .cmfy,
                     .cmra,
                     .proj,
                     .pack:
                    try readContainer(child, path: path + [type])
                default:
                    try readLeaf(type, payload: child)
                }
                readTypes.insert(rawType)
            }

            for type in requiredTypes where !readTypes.contains(type) {
                unrecognizedPaths.append(path.map(\.rawValue) + [type])
            }
        }

        /// The boxes of a payload, in order. Each must fit, and none may be of size zero.
        private func children(of payload: BlockBufferReader) throws(ReadError) -> [(UInt32, BlockBufferReader)] {
            var children: [(UInt32, BlockBufferReader)] = []
            var position = payload.readerIndex
            let end = payload.readerIndex + payload.readableBytes
            while position < end {
                guard end - position >= MP4Box.headerSize,
                      let size = try? Int(payload.getInt(at: position, as: UInt32.self)),
                      size >= MP4Box.headerSize, size <= end - position,
                      let type = try? payload.getInt(at: position + 4, as: UInt32.self),
                      let child = try? payload.getSlice(at: position + MP4Box.headerSize, length: size - MP4Box.headerSize) else {
                    throw .malformed
                }
                children.append((type, child))
                position += size
            }
            return children
        }

        /// A `must` box: version and flags, then the types of the required boxes.
        private func requiredBoxTypes(_ payload: BlockBufferReader) throws(ReadError) -> [UInt32] {
            guard payload.readableBytes >= 4, payload.readableBytes % 4 == 0 else {
                throw .malformed
            }
            let offsets = stride(from: payload.readerIndex + 4, to: payload.readerIndex + payload.readableBytes, by: 4)
            return try offsets.map { index throws(ReadError) -> UInt32 in
                guard let type = try? payload.getInt(at: index, as: UInt32.self) else {
                    throw .malformed
                }
                return type
            }
        }

        /// A box of one field after its version and flags, which must have the field's size.
        private func field<T: FixedWidthInteger>(_ payload: BlockBufferReader, as: T.Type) throws(ReadError) -> T {
            guard payload.readableBytes == 4 + MemoryLayout<T>.size,
                  let value = try? payload.getInt(at: payload.readerIndex + 4, as: T.self) else {
                throw .malformed
            }
            return value
        }

        private mutating func readLeaf(_ type: MP4Box.BoxType, payload: BlockBufferReader) throws(ReadError) {
            typealias Key = SampleDescriptionExtensionKey
            switch type {
            case .stri:
                // Stereo view information: has left eye (bit 0), right eye (1), additional views (2), eye views
                // reversed (3).
                let flags = try field(payload, as: UInt8.self)
                let keys = [Key.hasLeftStereoEyeView, Key.hasRightStereoEyeView, Key.hasAdditionalViews, Key.hasEyeViewsReversed]
                for (bit, key) in keys.enumerated() where flags & (1 << bit) != 0 {
                    extensions.addFirst(kCFBooleanTrue as Any, for: key)
                }
            case .hero:
                let eye = switch try field(payload, as: UInt8.self) {
                case 0: "Unspecified"
                case 1: "Left"
                case 2: "Right"
                default: "Reserved"
                }
                extensions.addFirst(eye, for: Key.heroEye)
            case .blin:
                // The baseline between the cameras, in micrometers.
                try extensions.addFirst(SampleDescriptionExtensions.number(field(payload, as: UInt32.self)), for: Key.stereoCameraBaseline)
            case .dadj:
                try extensions.addFirst(SampleDescriptionExtensions.number(field(payload, as: Int32.self)), for: Key.horizontalDisparityAdjustment)
            case .tiny:
                try extensions.addFirst(SampleDescriptionExtensions.number(field(payload, as: UInt32.self)), for: Key.transportIdentifier)
            case .prji:
                let kind: String? = switch try MP4Box.BoxType(rawValue: field(payload, as: UInt32.self)) {
                case .rect?: "Rectilinear"
                case .equi?: "Equirectangular"
                case .hequ?: "HalfEquirectangular"
                case .fish?: "AppleImmersiveVideo"
                case .prim?: "ParametricImmersive"
                default: nil
                }
                if let kind { extensions.addFirst(kind, for: Key.projectionKind) }
            case .pkin:
                let packing = try field(payload, as: UInt32.self)
                let kind: String? = switch MP4Box.BoxType(rawValue: packing) {
                case .side?: "SideBySide"
                case .over?: "OverUnder"
                default: packing == 0 ? "Unspecified" : nil
                }
                if let kind { extensions.addFirst(kind, for: Key.viewPackingKind) }
            default:
                break
            }
        }
    }
}
