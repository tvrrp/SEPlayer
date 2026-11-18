//
//  DvbParser.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import CoreGraphics
import CoreMedia
import Foundation
import SEPlayerCommon

/// Parses DVB subtitles (ETSI EN 300 743) into bitmap cues.
///
/// A sample is a display set: segments that define the page, its regions, their color tables and the objects drawn in
/// them. The page of the service, and the ancillary page shared between services, keep their definitions from one
/// display set to the next. Each display set emits one cue per region of the page, which replaces the cues before.
///
/// Supports display definitions, page, region, CLUT and object segments with 2, 4 and 8-bit pixel code strings and
/// map tables. Objects coded as character strings are not drawn.
public final class DvbParser: SubtitleParser {
    public static let cueReplacementBehavior: Format.CueReplacementBehavior = .replace

    private let service: SubtitleService

    /// - Parameter initializationData: The subtitling descriptor's composition page id and ancillary page id.
    public init(initializationData: [BlockBufferReader]) throws {
        guard let data = initializationData.first, data.readableBytes >= 4 else {
            throw ParserError.createForMalformedContainer(message: "DVB subtitles without page ids")
        }
        var reader = SubtitleBitReader(data.readableBytesView)
        service = SubtitleService(pageId: reader.readBits(16), ancillaryPageId: reader.readBits(16))
    }

    public func getCueReplacementBehavior() -> Format.CueReplacementBehavior {
        Self.cueReplacementBehavior
    }

    public func reset() {
        service.reset()
    }

    public func parse(
        data: BlockBufferReader,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws {
        var reader = SubtitleBitReader(data.readableBytesView)

        // Each segment: sync_byte, then a header of 40 bits.
        while reader.bitsLeft >= 48, reader.readBits(8) == 0x0F {
            parseSegment(&reader)
        }

        guard let page = service.page else {
            try output(CuesWithTiming(cues: [], startTime: .invalid, duration: .invalid))
            return
        }
        let duration = page.timeout > 0 ? CMTime(value: CMTimeValue(page.timeout), timescale: 1) : .invalid
        try output(CuesWithTiming(cues: cues(of: page), startTime: .invalid, duration: duration))
    }

    // MARK: - Cues

    /// One cue per region of the page, with the image of the objects in it.
    private func cues(of page: PageComposition) -> [Cue] {
        let display = service.displayDefinition ?? .default
        var cues: [Cue] = []

        for (regionId, pageRegion) in page.regions.sorted(by: { $0.key < $1.key }) {
            guard let region = service.regions[regionId], region.width > 0, region.height > 0 else {
                continue
            }
            let left = pageRegion.horizontalAddress + display.horizontalPositionMinimum
            let top = pageRegion.verticalAddress + display.verticalPositionMinimum
            // Only what is inside the display window shows.
            let visibleWidth = min(region.width, display.horizontalPositionMaximum - left)
            let visibleHeight = min(region.height, display.verticalPositionMaximum - top)
            guard visibleWidth > 0, visibleHeight > 0 else { continue }

            let clut = service.cluts[region.clutId] ?? service.ancillaryCluts[region.clutId] ?? .default
            var canvas = Canvas(width: region.width, height: region.height, visibleWidth: visibleWidth, visibleHeight: visibleHeight)

            for (objectId, regionObject) in region.objects.sorted(by: { $0.key < $1.key }) {
                // An object with non-modifying color is not drawn.
                guard let object = service.objects[objectId] ?? service.ancillaryObjects[objectId],
                      !object.nonModifyingColor else {
                    continue
                }
                Self.paintObject(
                    object,
                    clut: clut,
                    depth: region.depth,
                    x: regionObject.horizontalPosition,
                    y: regionObject.verticalPosition,
                    into: &canvas
                )
            }

            if region.fillFlag {
                let color = switch region.depth {
                case Self.regionDepth8Bit: clut.entries8Bit[region.pixelCode8Bit]
                case Self.regionDepth4Bit: clut.entries4Bit[region.pixelCode4Bit]
                default: clut.entries2Bit[region.pixelCode2Bit]
                }
                canvas.fillBehind(color)
            }

            guard let image = canvas.makeImage() else { continue }
            cues.append(Cue.Builder()
                .setImage(image)
                .setPosition(CGFloat(left) / CGFloat(display.width))
                .setPositionAnchor(.start)
                .setLine(.fraction(CGFloat(top) / CGFloat(display.height)))
                .setLineAnchor(.start)
                .setSize(CGFloat(region.width) / CGFloat(display.width))
                .setImageHeight(CGFloat(region.height) / CGFloat(display.height))
                .build())
        }
        return cues
    }

    // MARK: - Segments

    private func parseSegment(_ reader: inout SubtitleBitReader<BlockBufferView>) {
        let segmentType = reader.readBits(8)
        let pageId = reader.readBits(16)
        let length = reader.readBits(16)
        guard length * 8 <= reader.bitsLeft else {
            SELogger.debug(.subtitles, "DVB segment longer than its display set")
            reader.skipBits(reader.bitsLeft)
            return
        }
        let end = reader.bytePosition + length
        let isPage = pageId == service.pageId
        let isAncillaryPage = pageId == service.ancillaryPageId

        switch segmentType {
        case SegmentType.displayDefinition where isPage:
            service.displayDefinition = Self.parseDisplayDefinition(&reader)
        case SegmentType.pageComposition where isPage:
            let page = Self.parsePageComposition(&reader, length: length)
            if page.state != Self.pageStateNormal {
                // An acquisition point or a new page: everything is defined again.
                service.page = page
                service.regions.removeAll()
                service.cluts.removeAll()
                service.objects.removeAll()
            } else if let current = service.page, current.version != page.version {
                service.page = page
            }
        case SegmentType.regionComposition where isPage && service.page != nil:
            var region = Self.parseRegionComposition(&reader, length: length)
            if service.page?.state == Self.pageStateNormal, let existing = service.regions[region.id] {
                // An update keeps the objects it doesn't mention.
                region.objects.merge(existing.objects) { new, _ in new }
            }
            service.regions[region.id] = region
        case SegmentType.clutDefinition where isPage || isAncillaryPage:
            let clut = Self.parseClutDefinition(&reader, length: length)
            if isPage {
                service.cluts[clut.id] = clut
            } else {
                service.ancillaryCluts[clut.id] = clut
            }
        case SegmentType.objectData where isPage || isAncillaryPage:
            let object = Self.parseObjectData(&reader)
            if isPage {
                service.objects[object.id] = object
            } else {
                service.ancillaryObjects[object.id] = object
            }
        default:
            break
        }

        reader.skipBits((end - reader.bytePosition) * 8)
    }

    private static func parseDisplayDefinition(_ reader: inout SubtitleBitReader<BlockBufferView>) -> DisplayDefinition {
        reader.skipBits(4) // dds_version_number
        let hasDisplayWindow = reader.readBit()
        reader.skipBits(3)
        let width = reader.readBits(16)
        let height = reader.readBits(16)
        guard hasDisplayWindow else {
            return DisplayDefinition(
                width: width,
                height: height,
                horizontalPositionMinimum: 0,
                horizontalPositionMaximum: width,
                verticalPositionMinimum: 0,
                verticalPositionMaximum: height
            )
        }
        return DisplayDefinition(
            width: width,
            height: height,
            horizontalPositionMinimum: reader.readBits(16),
            horizontalPositionMaximum: reader.readBits(16),
            verticalPositionMinimum: reader.readBits(16),
            verticalPositionMaximum: reader.readBits(16)
        )
    }

    private static func parsePageComposition(_ reader: inout SubtitleBitReader<BlockBufferView>, length: Int) -> PageComposition {
        let timeout = reader.readBits(8)
        let version = reader.readBits(4)
        let state = reader.readBits(2)
        reader.skipBits(2)
        var remaining = length - 2
        var regions: [Int: PageRegion] = [:]
        while remaining > 0 {
            let regionId = reader.readBits(8)
            reader.skipBits(8)
            regions[regionId] = PageRegion(horizontalAddress: reader.readBits(16), verticalAddress: reader.readBits(16))
            remaining -= 6
        }
        return PageComposition(timeout: timeout, version: version, state: state, regions: regions)
    }

    private static func parseRegionComposition(_ reader: inout SubtitleBitReader<BlockBufferView>, length: Int) -> RegionComposition {
        let id = reader.readBits(8)
        reader.skipBits(4) // region_version_number
        let fillFlag = reader.readBit()
        reader.skipBits(3)
        let width = reader.readBits(16)
        let height = reader.readBits(16)
        reader.skipBits(3) // region_level_of_compatibility
        let depth = reader.readBits(3)
        reader.skipBits(2)
        let clutId = reader.readBits(8)
        let pixelCode8Bit = reader.readBits(8)
        let pixelCode4Bit = reader.readBits(4)
        let pixelCode2Bit = reader.readBits(2)
        reader.skipBits(2)
        var remaining = length - 10

        var objects: [Int: RegionObject] = [:]
        while remaining > 0 {
            let objectId = reader.readBits(16)
            let objectType = reader.readBits(2)
            reader.skipBits(2) // object_provider_flag
            let horizontalPosition = reader.readBits(12)
            reader.skipBits(4)
            let verticalPosition = reader.readBits(12)
            remaining -= 6
            if objectType == 0x01 || objectType == 0x02 {
                // Foreground and background pixel codes, for character objects.
                reader.skipBits(16)
                remaining -= 2
            }
            objects[objectId] = RegionObject(horizontalPosition: horizontalPosition, verticalPosition: verticalPosition)
        }

        return RegionComposition(
            id: id, fillFlag: fillFlag, width: width, height: height, depth: depth, clutId: clutId,
            pixelCode8Bit: pixelCode8Bit, pixelCode4Bit: pixelCode4Bit, pixelCode2Bit: pixelCode2Bit, objects: objects
        )
    }

    private static func parseClutDefinition(_ reader: inout SubtitleBitReader<BlockBufferView>, length: Int) -> ClutDefinition {
        let id = reader.readBits(8)
        reader.skipBits(8) // CLUT_version_number, reserved
        var remaining = length - 2
        var clut = ClutDefinition.default.with(id: id)

        while remaining > 0 {
            let entryId = reader.readBits(8)
            let flags = reader.readBits(8)
            remaining -= 2

            var y: Int
            var cr: Int
            var cb: Int
            var t: Int
            if flags & 0x01 != 0 {
                y = reader.readBits(8)
                cr = reader.readBits(8)
                cb = reader.readBits(8)
                t = reader.readBits(8)
                remaining -= 4
            } else {
                y = reader.readBits(6) << 2
                cr = reader.readBits(4) << 4
                cb = reader.readBits(4) << 4
                t = reader.readBits(2) << 6
                remaining -= 2
            }
            // Y of 0 is transparent.
            if y == 0 {
                cr = 0
                cb = 0
                t = 0xFF
            }

            let alpha = 0xFF - (t & 0xFF)
            let red = clamp(Double(y) + 1.402 * Double(cr - 128))
            let green = clamp(Double(y) - 0.34414 * Double(cb - 128) - 0.71414 * Double(cr - 128))
            let blue = clamp(Double(y) + 1.772 * Double(cb - 128))
            let color = argb(alpha, red, green, blue)

            if flags & 0x80 != 0 {
                if entryId < clut.entries2Bit.count { clut.entries2Bit[entryId] = color }
            } else if flags & 0x40 != 0 {
                if entryId < clut.entries4Bit.count { clut.entries4Bit[entryId] = color }
            } else {
                clut.entries8Bit[entryId] = color
            }
        }
        return clut
    }

    private static func parseObjectData(_ reader: inout SubtitleBitReader<BlockBufferView>) -> ObjectData {
        let id = reader.readBits(16)
        reader.skipBits(4) // object_version_number
        let codingMethod = reader.readBits(2)
        let nonModifyingColor = reader.readBit()
        reader.skipBits(1)

        var topField: BlockBufferView?
        var bottomField: BlockBufferView?
        if codingMethod == objectCodingString {
            let numberOfCodes = reader.readBits(8)
            reader.skipBits(numberOfCodes * 16)
        } else if codingMethod == objectCodingPixels {
            let topLength = reader.readBits(16)
            let bottomLength = reader.readBits(16)
            topField = reader.readBytes(topLength)
            // Without a bottom field, the top field is both.
            bottomField = bottomLength > 0 ? reader.readBytes(bottomLength) : topField
        }
        return ObjectData(id: id, nonModifyingColor: nonModifyingColor, topField: topField, bottomField: bottomField)
    }

    // MARK: - Pixels

    private static func paintObject(
        _ object: ObjectData,
        clut: ClutDefinition,
        depth: Int,
        x: Int,
        y: Int,
        into canvas: inout Canvas
    ) {
        let entries = switch depth {
        case regionDepth8Bit: clut.entries8Bit
        case regionDepth4Bit: clut.entries4Bit
        default: clut.entries2Bit
        }
        // Fields interlace: the top one on even lines, the bottom one on odd lines.
        paintPixelData(object.topField, entries: entries, depth: depth, x: x, y: y, into: &canvas)
        paintPixelData(object.bottomField, entries: entries, depth: depth, x: x, y: y + 1, into: &canvas)
    }

    private static func paintPixelData(
        _ pixelData: BlockBufferView?,
        entries: [UInt32],
        depth: Int,
        x: Int,
        y: Int,
        into canvas: inout Canvas
    ) {
        guard let pixelData else { return }
        var reader = SubtitleBitReader(pixelData)
        var column = x
        var line = y
        var map2To4: [Int]?
        var map2To8: [Int]?
        var map4To8: [Int]?

        while reader.bitsLeft >= 8 {
            switch reader.readBits(8) {
            case DataType.twoBitString:
                let map: [Int]? = switch depth {
                case regionDepth8Bit: map2To8 ?? defaultMap2To8
                case regionDepth4Bit: map2To4 ?? defaultMap2To4
                default: nil
                }
                column = paintCodeString(&reader, bits: 2, entries: entries, map: map, column: column, line: line, into: &canvas)
                reader.byteAlign()
            case DataType.fourBitString:
                let map = depth == regionDepth8Bit ? map4To8 ?? defaultMap4To8 : nil
                column = paintCodeString(&reader, bits: 4, entries: entries, map: map, column: column, line: line, into: &canvas)
                reader.byteAlign()
            case DataType.eightBitString:
                column = paintCodeString(&reader, bits: 8, entries: entries, map: nil, column: column, line: line, into: &canvas)
            case DataType.map2To4:
                map2To4 = (0..<4).map { _ in reader.readBits(4) }
            case DataType.map2To8:
                map2To8 = (0..<4).map { _ in reader.readBits(8) }
            case DataType.map4To8:
                map4To8 = (0..<16).map { _ in reader.readBits(8) }
            case DataType.endOfLine:
                column = x
                line += 2
            default:
                break
            }
        }
    }

    /// Paints a run-length coded string of pixels of `bits` bits each, and returns the column after it.
    private static func paintCodeString(
        _ reader: inout SubtitleBitReader<BlockBufferView>,
        bits: Int,
        entries: [UInt32],
        map: [Int]?,
        column: Int,
        line: Int,
        into canvas: inout Canvas
    ) -> Int {
        var column = column
        while reader.bitsLeft > 0 {
            guard let (runLength, code) = nextRun(&reader, bits: bits) else {
                break
            }
            if runLength > 0 {
                let index = map.map { $0[code] } ?? code
                canvas.paint(entries[index & (entries.count - 1)], x: column, y: line, length: runLength)
            }
            column += runLength
        }
        return column
    }

    /// The next run of a pixel code string: its length and pixel code, or `nil` at the end of the string.
    private static func nextRun(_ reader: inout SubtitleBitReader<BlockBufferView>, bits: Int) -> (Int, Int)? {
        switch bits {
        case 2:
            let peek = reader.readBits(2)
            if peek != 0 { return (1, peek) }
            if reader.readBit() {
                let length = 3 + reader.readBits(3)
                return (length, reader.readBits(2))
            }
            if reader.readBit() { return (1, 0) }
            switch reader.readBits(2) {
            case 0x00: return nil
            case 0x01: return (2, 0)
            case 0x02:
                let length = 12 + reader.readBits(4)
                return (length, reader.readBits(2))
            default:
                let length = 29 + reader.readBits(8)
                return (length, reader.readBits(2))
            }
        case 4:
            let peek = reader.readBits(4)
            if peek != 0 { return (1, peek) }
            if !reader.readBit() {
                let length = reader.readBits(3)
                return length != 0 ? (2 + length, 0) : nil
            }
            if !reader.readBit() {
                let length = 4 + reader.readBits(2)
                return (length, reader.readBits(4))
            }
            switch reader.readBits(2) {
            case 0x00: return (1, 0)
            case 0x01: return (2, 0)
            case 0x02:
                let length = 9 + reader.readBits(4)
                return (length, reader.readBits(4))
            default:
                let length = 25 + reader.readBits(8)
                return (length, reader.readBits(4))
            }
        default:
            let peek = reader.readBits(8)
            if peek != 0 { return (1, peek) }
            if !reader.readBit() {
                let length = reader.readBits(7)
                return length != 0 ? (length, 0) : nil
            }
            let length = reader.readBits(7)
            return (length, reader.readBits(8))
        }
    }

    // MARK: - Constants

    private enum SegmentType {
        static let pageComposition = 0x10
        static let regionComposition = 0x11
        static let clutDefinition = 0x12
        static let objectData = 0x13
        static let displayDefinition = 0x14
    }

    private enum DataType {
        static let twoBitString = 0x10
        static let fourBitString = 0x11
        static let eightBitString = 0x12
        static let map2To4 = 0x20
        static let map2To8 = 0x21
        static let map4To8 = 0x22
        static let endOfLine = 0xF0
    }

    /// A page update, which changes only what it mentions.
    private static let pageStateNormal = 0
    private static let regionDepth4Bit = 2
    private static let regionDepth8Bit = 3
    private static let objectCodingPixels = 0
    private static let objectCodingString = 1

    private static let defaultMap2To4 = [0x00, 0x07, 0x08, 0x0F]
    private static let defaultMap2To8 = [0x00, 0x77, 0x88, 0xFF]
    private static let defaultMap4To8 = [
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    ]

    fileprivate static func argb(_ alpha: Int, _ red: Int, _ green: Int, _ blue: Int) -> UInt32 {
        UInt32(alpha) << 24 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    private static func clamp(_ value: Double) -> Int {
        Int(min(255, max(0, value)))
    }
}

// MARK: - Model

/// The definitions of a page and its ancillary page, kept from one display set to the next.
private final class SubtitleService {
    let pageId: Int
    let ancillaryPageId: Int

    var displayDefinition: DisplayDefinition?
    var page: PageComposition?
    var regions: [Int: RegionComposition] = [:]
    var cluts: [Int: ClutDefinition] = [:]
    var objects: [Int: ObjectData] = [:]
    var ancillaryCluts: [Int: ClutDefinition] = [:]
    var ancillaryObjects: [Int: ObjectData] = [:]

    init(pageId: Int, ancillaryPageId: Int) {
        self.pageId = pageId
        self.ancillaryPageId = ancillaryPageId
    }

    func reset() {
        displayDefinition = nil
        page = nil
        regions.removeAll()
        cluts.removeAll()
        objects.removeAll()
        ancillaryCluts.removeAll()
        ancillaryObjects.removeAll()
    }
}

/// The display the page is drawn on. Widths and heights are one less than the pixels.
private struct DisplayDefinition {
    let width: Int
    let height: Int
    let horizontalPositionMinimum: Int
    let horizontalPositionMaximum: Int
    let verticalPositionMinimum: Int
    let verticalPositionMaximum: Int

    /// Standard definition, 720 by 576.
    static let `default` = DisplayDefinition(
        width: 719, height: 575, horizontalPositionMinimum: 0, horizontalPositionMaximum: 719,
        verticalPositionMinimum: 0, verticalPositionMaximum: 575
    )
}

private struct PageComposition {
    /// Seconds the page shows, at most.
    let timeout: Int
    let version: Int
    let state: Int
    let regions: [Int: PageRegion]
}

private struct PageRegion {
    let horizontalAddress: Int
    let verticalAddress: Int
}

private struct RegionComposition {
    let id: Int
    let fillFlag: Bool
    let width: Int
    let height: Int
    let depth: Int
    let clutId: Int
    let pixelCode8Bit: Int
    let pixelCode4Bit: Int
    let pixelCode2Bit: Int
    var objects: [Int: RegionObject]
}

private struct RegionObject {
    let horizontalPosition: Int
    let verticalPosition: Int
}

private struct ObjectData {
    let id: Int
    let nonModifyingColor: Bool
    /// The pixel data of each field, in the display set's buffer; `nil` for objects without pixels.
    let topField: BlockBufferView?
    let bottomField: BlockBufferView?
}

/// The colors of 2, 4 and 8-bit pixel codes, as ARGB.
private struct ClutDefinition {
    var id: Int
    var entries2Bit: [UInt32]
    var entries4Bit: [UInt32]
    var entries8Bit: [UInt32]

    func with(id: Int) -> ClutDefinition {
        var clut = self
        clut.id = id
        return clut
    }

    /// The default tables of ETSI EN 300 743, 10.
    static let `default` = ClutDefinition(
        id: 0,
        entries2Bit: [0x0000_0000, 0xFFFF_FFFF, 0xFF00_0000, 0xFF7F_7F7F],
        entries4Bit: (0..<16).map { index in
            guard index > 0 else { return 0 }
            let value = index < 8 ? 0xFF : 0x7F
            return DvbParser.argb(
                0xFF,
                index & 0x01 != 0 ? value : 0,
                index & 0x02 != 0 ? value : 0,
                index & 0x04 != 0 ? value : 0
            )
        },
        entries8Bit: (0..<256).map { index in
            guard index > 0 else { return 0 }
            func component(_ low: Int, _ high: Int, _ lowValue: Int, _ highValue: Int, base: Int = 0) -> Int {
                base + (index & low != 0 ? lowValue : 0) + (index & high != 0 ? highValue : 0)
            }
            if index < 8 {
                return DvbParser.argb(
                    0x3F,
                    index & 0x01 != 0 ? 0xFF : 0,
                    index & 0x02 != 0 ? 0xFF : 0,
                    index & 0x04 != 0 ? 0xFF : 0
                )
            }
            switch index & 0x88 {
            case 0x00:
                return DvbParser.argb(
                    0xFF,
                    component(0x01, 0x10, 0x55, 0xAA),
                    component(0x02, 0x20, 0x55, 0xAA),
                    component(0x04, 0x40, 0x55, 0xAA)
                )
            case 0x08:
                return DvbParser.argb(
                    0x7F,
                    component(0x01, 0x10, 0x55, 0xAA),
                    component(0x02, 0x20, 0x55, 0xAA),
                    component(0x04, 0x40, 0x55, 0xAA)
                )
            case 0x80:
                return DvbParser.argb(
                    0xFF,
                    component(0x01, 0x10, 0x2B, 0x55, base: 127),
                    component(0x02, 0x20, 0x2B, 0x55, base: 127),
                    component(0x04, 0x40, 0x2B, 0x55, base: 127)
                )
            default:
                return DvbParser.argb(
                    0xFF,
                    component(0x01, 0x10, 0x2B, 0x55),
                    component(0x02, 0x20, 0x2B, 0x55),
                    component(0x04, 0x40, 0x2B, 0x55)
                )
            }
        }
    )
}

/// The pixels of a region, ARGB, of which only the visible part is painted.
///
/// The pixels are allocated once, painted in place, and become the image's own: making the image consumes the
/// canvas, and the image frees them when it goes.
private struct Canvas: ~Copyable {
    let width: Int
    let height: Int
    let visibleWidth: Int
    let visibleHeight: Int
    private let pixels: UnsafeMutableBufferPointer<UInt32>

    init(width: Int, height: Int, visibleWidth: Int, visibleHeight: Int) {
        self.width = width
        self.height = height
        self.visibleWidth = visibleWidth
        self.visibleHeight = visibleHeight
        pixels = .allocate(capacity: width * height)
        pixels.initialize(repeating: 0)
    }

    deinit {
        pixels.deallocate()
    }

    /// Replaces the pixels of a run, alpha included.
    mutating func paint(_ color: UInt32, x: Int, y: Int, length: Int) {
        guard y >= 0, y < visibleHeight else { return }
        let start = max(0, x)
        let end = min(x + length, visibleWidth)
        guard start < end else { return }
        let row = y * width
        UnsafeMutableBufferPointer(rebasing: pixels[(row + start)..<(row + end)]).update(repeating: color)
    }

    /// Fills the transparent pixels of the visible part with `color`, as if under them.
    mutating func fillBehind(_ color: UInt32) {
        for y in 0..<visibleHeight {
            let row = y * width
            for x in 0..<visibleWidth where pixels[row + x] >> 24 == 0 {
                pixels[row + x] = color
            }
        }
    }

    /// The image of the pixels, which takes them over.
    consuming func makeImage() -> CGImage? {
        let pixels = pixels
        let (width, height) = (width, height)
        discard self

        let provider = CGDataProvider(
            dataInfo: nil,
            data: pixels.baseAddress!,
            size: pixels.count * MemoryLayout<UInt32>.size,
            releaseData: { _, data, _ in data.deallocate() }
        )
        guard let provider else {
            pixels.deallocate()
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * MemoryLayout<UInt32>.size,
            space: CGColorSpaceCreateDeviceRGB(),
            // 32-bit values, alpha in the high byte, not premultiplied.
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
