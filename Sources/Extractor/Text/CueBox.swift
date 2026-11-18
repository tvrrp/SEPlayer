//
//  CueBox.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//

import CoreGraphics
import CoreMedia
import SEPlayerCommon

/// The binary format of cue samples, laid out as MP4 boxes: a `UInt32` size, which counts the 8 bytes of the header, a
/// `UInt32` type and the payload. Integers are big endian. A container box holds other boxes as its payload.
///
/// Readers skip boxes of types they don't know, so new types can be added without breaking old data.
///
/// ```
/// cues                    CuesWithTiming
///   dura                  duration: Int64 value, Int32 timescale, UInt32 flags, Int64 epoch
///   cue                   Cue, one box per cue
///     text                text, container
///       strg              UTF-8 string
///       span              UInt32 location, UInt32 length (UTF-16 units, as NSRange), then attribute boxes:
///         fgcl bgcl       color
///         undl            Int32 CTUnderlineStyle
///         strk hinv       UInt8 bool
///         trai            UInt32 CTFontSymbolicTraits
///         fmly voic       UTF-8 string
///         rsiz asiz       Float64
///         ruby            UInt8 position, UTF-8 string
///         emph            UInt8 shape, UInt8 fill, UInt8 position
///     imag                UInt32 width, UInt32 height, RGBA pixels: 8 bits, premultiplied alpha, sRGB
///     talg malg           UInt8 Cue.Alignment
///     line                UInt8 kind (0 fraction, 1 number), then Float64 fraction or Int64 number
///     lanc panc           UInt8 Cue.Anchor
///     posn size imgh shea Float64
///     wcol                color
///     tsiz                UInt8 kind (0 fractional, 1 ignoring padding, 2 absolute), Float64 size
///     vert                UInt8 Cue.VerticalType
///     zidx                Int32
/// ```
/// Colors are four `Float32` sRGB components: red, green, blue, alpha. A position of 0 means unset.
struct CueBoxType: RawRepresentable, Hashable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(_ fourCC: StaticString) {
        precondition(fourCC.utf8CodeUnitCount == 4)
        rawValue = fourCC.withUTF8Buffer { $0.reduce(0) { ($0 << 8) | UInt32($1) } }
    }

    static let cues = CueBoxType("cues")
    static let duration = CueBoxType("dura")
    static let cue = CueBoxType("cue ")

    static let text = CueBoxType("text")
    static let string = CueBoxType("strg")
    static let span = CueBoxType("span")
    static let foregroundColor = CueBoxType("fgcl")
    static let backgroundColor = CueBoxType("bgcl")
    static let underline = CueBoxType("undl")
    static let strikethrough = CueBoxType("strk")
    static let bold = CueBoxType("bold")
    static let italic = CueBoxType("ital")
    static let fontFamily = CueBoxType("fmly")
    static let relativeFontSize = CueBoxType("rsiz")
    static let absoluteFontSize = CueBoxType("asiz")
    static let ruby = CueBoxType("ruby")
    static let textEmphasis = CueBoxType("emph")
    static let horizontalInVertical = CueBoxType("hinv")
    static let voice = CueBoxType("voic")

    static let image = CueBoxType("imag")
    static let textAlignment = CueBoxType("talg")
    static let multiRowAlignment = CueBoxType("malg")
    static let line = CueBoxType("line")
    static let lineAnchor = CueBoxType("lanc")
    static let position = CueBoxType("posn")
    static let positionAnchor = CueBoxType("panc")
    static let size = CueBoxType("size")
    static let imageHeight = CueBoxType("imgh")
    static let windowColor = CueBoxType("wcol")
    static let textSize = CueBoxType("tsiz")
    static let verticalType = CueBoxType("vert")
    static let shearDegrees = CueBoxType("shea")
    static let zIndex = CueBoxType("zidx")
}

struct CueBoxWriter {
    private(set) var bytes: [UInt8] = []

    /// Writes a box: its payload is what `body` writes.
    mutating func box(_ type: CueBoxType, _ body: (inout CueBoxWriter) throws -> Void = { _ in }) throws {
        let start = bytes.count
        append(UInt32.zero)
        append(type.rawValue)
        try body(&self)

        guard let size = UInt32(exactly: bytes.count - start) else {
            throw CueBoxError.boxTooLarge
        }
        withUnsafeBytes(of: size.bigEndian) { bytes.replaceSubrange(start ..< (start + 4), with: $0) }
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func append(_ value: CGFloat) {
        append(Double(value).bitPattern)
    }

    mutating func append(_ value: Bool) {
        append(UInt8(value ? 1 : 0))
    }

    mutating func append(bytes: [UInt8]) {
        self.bytes.append(contentsOf: bytes)
    }

    mutating func append(_ value: String) {
        bytes.append(contentsOf: value.utf8)
    }

    mutating func append(_ time: CMTime) {
        append(time.value)
        append(time.timescale)
        append(time.flags.rawValue)
        append(time.epoch)
    }

    mutating func append(_ color: CGColor) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color.converted(to: colorSpace, intent: .defaultIntent, options: nil)?.components,
              components.count == 4 else {
            throw CueBoxError.unsupportedColor
        }
        components.forEach { append(Float32($0).bitPattern) }
    }

    mutating func append(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CueBoxError.unsupportedImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else {
            throw CueBoxError.unsupportedImage
        }

        append(UInt32(width))
        append(UInt32(height))
        bytes.append(contentsOf: UnsafeRawBufferPointer(start: pixels, count: width * height * 4))
    }
}

/// Reads boxes from `reader`'s readable bytes.
struct CueBoxReader {
    private var reader: BlockBufferReader

    init(_ reader: BlockBufferReader) {
        self.reader = reader
    }

    /// Calls `body` with each box: its type and a reader of its payload.
    mutating func forEachBox(_ body: (CueBoxType, inout CueBoxReader) throws -> Void) throws {
        while reader.readableBytes > 0 {
            guard reader.readableBytes >= 8 else { throw CueBoxError.malformed }
            let start = reader.readerIndex
            let size = try Int(reader.readInt(as: UInt32.self))
            let type = try CueBoxType(rawValue: reader.readInt(as: UInt32.self))
            guard size >= 8, size - 8 <= reader.readableBytes else {
                throw CueBoxError.malformed
            }

            var payload = try CueBoxReader(reader.getSlice(at: reader.readerIndex, length: size - 8))
            try body(type, &payload)
            reader.moveReaderIndex(to: start + size)
        }
    }

    mutating func read<T: FixedWidthInteger>(as type: T.Type = T.self) throws -> T {
        try reader.readInt(as: T.self)
    }

    mutating func readCGFloat() throws -> CGFloat {
        try CGFloat(Double(bitPattern: read(as: UInt64.self)))
    }

    mutating func readBool() throws -> Bool {
        try read(as: UInt8.self) != 0
    }

    /// Reads the rest of the payload as a UTF-8 string.
    mutating func readString() throws -> String {
        guard let string = reader.readString(length: reader.readableBytes, encoding: .utf8) else {
            throw CueBoxError.malformed
        }
        return string
    }

    mutating func readTime() throws -> CMTime {
        try CMTime(
            value: read(),
            timescale: read(),
            flags: CMTimeFlags(rawValue: read()),
            epoch: read()
        )
    }

    mutating func readColor() throws -> CGColor {
        let components = try (0 ..< 4).map { _ in try CGFloat(Float32(bitPattern: read(as: UInt32.self))) }
        return CGColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    mutating func readImage() throws -> CGImage {
        let width = try Int(read(as: UInt32.self))
        let height = try Int(read(as: UInt32.self))
        let bytesPerRow = width * 4
        guard width > 0, height > 0, reader.readableBytes == bytesPerRow * height else {
            throw CueBoxError.malformed
        }

        let pixels = try reader.getData(at: reader.readerIndex, length: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw CueBoxError.malformed
        }
        return image
    }
}

enum CueBoxError: Error {
    case malformed
    case boxTooLarge
    case unsupportedColor
    case unsupportedImage
}
