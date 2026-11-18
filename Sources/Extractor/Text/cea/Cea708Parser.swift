//
//  Cea708Parser.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import CoreGraphics
import CoreMedia
import Foundation
import SEPlayerCommon

/// Parses CEA-708 (CTA-708-E) digital closed captions of one service.
///
/// The caption data carries DTVCC packets, made of service blocks; the blocks of the selected service define up to
/// eight windows and write text into them. The parser keeps the windows from one sample to the next, and emits the
/// visible ones as cues each time they change; each set replaces the one before.
///
/// Supports window definitions, visibility, positions and justification, window fill colors, pen colors, italics and
/// underline, and the G0, G1, G2 and G3 character sets. Pen locations within a window move to a new row only; window
/// borders, print and scroll directions, word wrap and delays are not supported.
public final class Cea708Parser: SubtitleParser {
    public static let cueReplacementBehavior: Format.CueReplacementBehavior = .replace

    private let selectedServiceNumber: Int
    private let windows: [Window] = (0 ..< Cea708Parser.windowCount).map { _ in Window() }
    private var currentWindow = 0
    private var currentPacket: DtvCcPacket?
    private var previousSequenceNumber: Int?
    /// The cues on screen.
    private var cues: [Cue] = []
    /// The cues last emitted.
    private var emittedCues: [Cue] = []

    /// - Parameter accessibilityChannel: The service number, 1 to 63; anything else is service 1.
    public init(accessibilityChannel: Int) {
        selectedServiceNumber = (1 ... 63).contains(accessibilityChannel) ? accessibilityChannel : 1
    }

    public func getCueReplacementBehavior() -> Format.CueReplacementBehavior {
        Self.cueReplacementBehavior
    }

    public func reset() {
        cues = []
        emittedCues = []
        currentWindow = 0
        currentPacket = nil
        previousSequenceNumber = nil
        resetWindows()
    }

    public func parse(
        data: BlockBufferReader,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws {
        let bytes = data.readableBytesView
        var index = bytes.startIndex

        while bytes.endIndex - index >= 3 {
            let header = bytes[index] & 0x07
            let ccData1 = bytes[index + 1]
            let ccData2 = bytes[index + 2]
            index += 3

            let ccType = header & 0x03
            // CEA-608 data.
            guard ccType == Self.packetData || ccType == Self.packetStart else {
                continue
            }
            guard header & 0x04 != 0 else {
                // A pair that isn't valid ends the packet.
                finalizeCurrentPacket()
                continue
            }

            if ccType == Self.packetStart {
                finalizeCurrentPacket()
                let sequenceNumber = Int(ccData1 & 0xC0) >> 6
                if let previousSequenceNumber, sequenceNumber != (previousSequenceNumber + 1) % 4 {
                    // A packet was lost: what the windows hold may be wrong.
                    SELogger.debug(.subtitles, "CEA-708 packet sequence \(previousSequenceNumber) → \(sequenceNumber): resetting")
                    resetWindows()
                }
                previousSequenceNumber = sequenceNumber
                let packetSize = Int(ccData1 & 0x3F)
                var packet = DtvCcPacket(size: packetSize == 0 ? 64 : packetSize)
                packet.data.append(ccData2)
                currentPacket = packet
            } else {
                guard currentPacket != nil else { continue }
                currentPacket?.data.append(contentsOf: [ccData1, ccData2])
            }

            if let currentPacket, currentPacket.data.count == currentPacket.size * 2 - 1 {
                finalizeCurrentPacket()
            }
        }

        if cues != emittedCues {
            emittedCues = cues
            try output(CuesWithTiming(cues: cues, startTime: .invalid, duration: .invalid))
        }
    }

    // MARK: - Packets

    private func finalizeCurrentPacket() {
        guard let packet = currentPacket else { return }
        currentPacket = nil
        guard !packet.data.isEmpty else { return }
        // A packet cut short, by a new one starting, may have lost bytes; what there is is still worth reading.
        processPacket(packet.data)
    }

    private func processPacket(_ data: [UInt8]) {
        // A packet is gathered from the pairs of many triplets: it has bytes of its own.
        var reader = SubtitleBitReader(data)
        var cuesNeedUpdate = false

        while reader.bitsLeft > 0 {
            // The service block header.
            var serviceNumber = reader.readBits(3)
            let blockSize = reader.readBits(5)
            if serviceNumber == 7 {
                // The extended service block header.
                reader.skipBits(2)
                serviceNumber = reader.readBits(6)
            }
            // The null service ends the packet.
            guard blockSize != 0 else { break }
            guard serviceNumber == selectedServiceNumber else {
                reader.skipBits(blockSize * 8)
                continue
            }

            let blockEnd = reader.position + blockSize * 8
            while reader.position < blockEnd, reader.bitsLeft >= 8 {
                var command = reader.readBits(8)
                if command != Command.ext1 {
                    switch command {
                    case ...0x1F:
                        handleC0Command(command, &reader)
                    case ...0x7F:
                        handleG0Character(command)
                        cuesNeedUpdate = true
                    case ...0x9F:
                        handleC1Command(command, &reader)
                        cuesNeedUpdate = true
                    default:
                        handleG1Character(command)
                        cuesNeedUpdate = true
                    }
                } else {
                    guard reader.bitsLeft >= 8 else { break }
                    command = reader.readBits(8)
                    switch command {
                    case ...0x1F:
                        handleC2Command(command, &reader)
                    case ...0x7F:
                        handleG2Character(command)
                        cuesNeedUpdate = true
                    case ...0x9F:
                        handleC3Command(command, &reader)
                    default:
                        handleG3Character(command)
                        cuesNeedUpdate = true
                    }
                }
            }
        }

        if cuesNeedUpdate {
            cues = displayCues()
        }
    }

    // MARK: - Commands

    private var window: Window { windows[currentWindow] }

    private func handleC0Command(_ command: Int, _ reader: inout SubtitleBitReader<[UInt8]>) {
        switch command {
        case Command.nul:
            break
        case Command.etx:
            cues = displayCues()
        case Command.backspace:
            window.backspace()
        case Command.formFeed:
            resetWindows()
        case Command.carriageReturn:
            window.append("\n")
        case Command.horizontalCarriageReturn:
            break
        case 0x11 ... 0x17:
            reader.skipBits(8)
        case 0x18 ... 0x1F:
            reader.skipBits(16)
        default:
            break
        }
    }

    private func handleC1Command(_ command: Int, _ reader: inout SubtitleBitReader<[UInt8]>) {
        switch command {
        case Command.setCurrentWindow0 ... Command.setCurrentWindow7:
            currentWindow = command - Command.setCurrentWindow0
        case Command.clearWindows:
            forEachWindowInBitmap(&reader) { $0.clear() }
        case Command.displayWindows:
            forEachWindowInBitmap(&reader) { $0.isVisible = true }
        case Command.hideWindows:
            forEachWindowInBitmap(&reader) { $0.isVisible = false }
        case Command.toggleWindows:
            forEachWindowInBitmap(&reader) { $0.isVisible.toggle() }
        case Command.deleteWindows:
            forEachWindowInBitmap(&reader) { $0.reset() }
        case Command.delay:
            reader.skipBits(8)
        case Command.delayCancel:
            break
        case Command.reset:
            resetWindows()
        case Command.setPenAttributes:
            guard window.isDefined else { return reader.skipBits(16) }
            reader.skipBits(8) // text tag, offset, pen size
            let italics = reader.readBit()
            let underline = reader.readBit()
            reader.skipBits(6) // edge type, font style
            window.setPenAttributes(italics: italics, underline: underline)
        case Command.setPenColor:
            guard window.isDefined else { return reader.skipBits(24) }
            let foreground = Self.readColor(&reader, withOpacity: true)
            let background = Self.readColor(&reader, withOpacity: true)
            reader.skipBits(8) // padding, edge color
            window.setPenColor(foreground: foreground, background: background)
        case Command.setPenLocation:
            guard window.isDefined else { return reader.skipBits(16) }
            reader.skipBits(4)
            let row = reader.readBits(4)
            reader.skipBits(8) // padding, column
            window.setPenLocation(row: row)
        case Command.setWindowAttributes:
            guard window.isDefined else { return reader.skipBits(32) }
            let fill = Self.readColor(&reader, withOpacity: true)
            reader.skipBits(8) // border type, border color
            reader.skipBits(6) // border type, word wrap, print direction, scroll direction
            let justification = reader.readBits(2)
            reader.skipBits(8) // effect speed, effect direction, display effect
            window.setWindowAttributes(fillColor: fill, justification: justification)
        case Command.defineWindow0 ... Command.defineWindow7:
            currentWindow = command - Command.defineWindow0
            defineWindow(windows[currentWindow], &reader)
        default:
            break
        }
    }

    /// C2 holds no commands, but their lengths are defined.
    private func handleC2Command(_ command: Int, _ reader: inout SubtitleBitReader<[UInt8]>) {
        switch command {
        case ...0x07: break
        case ...0x0F: reader.skipBits(8)
        case ...0x17: reader.skipBits(16)
        default: reader.skipBits(24)
        }
    }

    /// C3 holds no commands, but their lengths are defined.
    private func handleC3Command(_ command: Int, _ reader: inout SubtitleBitReader<[UInt8]>) {
        switch command {
        case ...0x87:
            reader.skipBits(32)
        case ...0x8F:
            reader.skipBits(40)
        default:
            // Variable length: the next byte has the length in its 6 lower bits.
            reader.skipBits(2)
            reader.skipBits(reader.readBits(6) * 8)
        }
    }

    private func handleG0Character(_ code: Int) {
        // 0x7F is a music note; the rest is ASCII.
        window.append(code == 0x7F ? "\u{266B}" : Character(Unicode.Scalar(UInt8(code))))
    }

    private func handleG1Character(_ code: Int) {
        // ISO 8859-1.
        window.append(Character(Unicode.Scalar(UInt8(code))))
    }

    private func handleG2Character(_ code: Int) {
        guard let scalar = Self.g2Characters[code].flatMap(Unicode.Scalar.init) else {
            return
        }
        window.append(Character(scalar))
    }

    private func handleG3Character(_ code: Int) {
        // Only the closed caption icon is defined; anything else shows as an underscore.
        window.append(code == 0xA0 ? "\u{33C4}" : "_")
    }

    private func defineWindow(_ window: Window, _ reader: inout SubtitleBitReader<[UInt8]>) {
        reader.skipBits(2)
        let isVisible = reader.readBit()
        reader.skipBits(2) // row lock, column lock
        let priority = reader.readBits(3)
        let relativePositioning = reader.readBit()
        let verticalAnchor = reader.readBits(7)
        let horizontalAnchor = reader.readBits(8)
        let anchorId = reader.readBits(4)
        let rowCount = reader.readBits(4)
        reader.skipBits(8) // padding, column count
        reader.skipBits(2)
        let windowStyle = reader.readBits(3)
        let penStyle = reader.readBits(3)

        window.define(
            isVisible: isVisible,
            priority: priority,
            relativePositioning: relativePositioning,
            verticalAnchor: verticalAnchor,
            horizontalAnchor: horizontalAnchor,
            anchorId: anchorId,
            rowCount: rowCount,
            windowStyle: windowStyle,
            penStyle: penStyle
        )
    }

    /// Calls `body` for the windows a bitmap of the eight of them selects, window 7 first.
    private func forEachWindowInBitmap(_ reader: inout SubtitleBitReader<[UInt8]>, _ body: (Window) -> Void) {
        for index in (0 ..< Self.windowCount).reversed() where reader.readBit() {
            body(windows[index])
        }
    }

    private func resetWindows() {
        windows.forEach { $0.reset() }
    }

    /// The visible windows, the least important first.
    private func displayCues() -> [Cue] {
        windows
            .filter { $0.isVisible }
            .compactMap { window in window.build().map { (cue: $0, priority: window.priority) } }
            // Priority 0 is the most important.
            .sorted { $0.priority > $1.priority }
            .map(\.cue)
    }

    // MARK: - Codes

    fileprivate static let windowCount = 8
    private static let packetData: UInt8 = 0x02
    private static let packetStart: UInt8 = 0x03

    private enum Command {
        // C0
        static let nul = 0x00
        static let etx = 0x03
        static let backspace = 0x08
        static let formFeed = 0x0C
        static let carriageReturn = 0x0D
        static let horizontalCarriageReturn = 0x0E
        static let ext1 = 0x10
        // C1
        static let setCurrentWindow0 = 0x80
        static let setCurrentWindow7 = 0x87
        static let clearWindows = 0x88
        static let displayWindows = 0x89
        static let hideWindows = 0x8A
        static let toggleWindows = 0x8B
        static let deleteWindows = 0x8C
        static let delay = 0x8D
        static let delayCancel = 0x8E
        static let reset = 0x8F
        static let setPenAttributes = 0x90
        static let setPenColor = 0x91
        static let setPenLocation = 0x92
        static let setWindowAttributes = 0x97
        static let defineWindow0 = 0x98
        static let defineWindow7 = 0x9F
    }

    private static let g2Characters: [Int: UInt32] = [
        0x20: 0x0020, // transparent space
        0x21: 0x00A0, // non-breaking transparent space
        0x25: 0x2026, 0x2A: 0x0160, 0x2C: 0x0152, 0x30: 0x2588, 0x31: 0x2018, 0x32: 0x2019, 0x33: 0x201C,
        0x34: 0x201D, 0x35: 0x2022, 0x39: 0x2122, 0x3A: 0x0161, 0x3C: 0x0153, 0x3D: 0x2120, 0x3F: 0x0178,
        0x76: 0x215B, 0x77: 0x215C, 0x78: 0x215D, 0x79: 0x215E, 0x7A: 0x2502, 0x7B: 0x2510, 0x7C: 0x2514,
        0x7D: 0x2500, 0x7E: 0x2518, 0x7F: 0x250C,
    ]

    /// A color of two bits per component, of the minimum color list, after two bits of opacity if `withOpacity`.
    private static func readColor(_ reader: inout SubtitleBitReader<[UInt8]>, withOpacity: Bool) -> Color {
        let opacity = withOpacity ? reader.readBits(2) : 0
        let red = reader.readBits(2)
        let green = reader.readBits(2)
        let blue = reader.readBits(2)
        return Color(red: red, green: green, blue: blue, opacity: opacity)
    }
}

/// A DTVCC packet being received: `size` pairs of bytes, less the header byte.
private struct DtvCcPacket {
    let size: Int
    var data: [UInt8] = []
}

/// A CEA-708 color, kept as its codes so equal colors compare equal.
private struct Color: Hashable {
    let red: Int
    let green: Int
    let blue: Int
    /// 0 solid, 1 flashing (shown solid), 2 translucent, 3 transparent.
    let opacity: Int

    static let solidWhite = Color(red: 2, green: 2, blue: 2, opacity: 0)
    static let solidBlack = Color(red: 0, green: 0, blue: 0, opacity: 0)
    static let transparent = Color(red: 0, green: 0, blue: 0, opacity: 3)

    var cgColor: CGColor {
        let alpha: CGFloat = switch opacity {
        case 2: 0.5
        case 3: 0
        default: 1
        }
        return CGColor(red: red > 1 ? 1 : 0, green: green > 1 ? 1 : 0, blue: blue > 1 ? 1 : 0, alpha: alpha)
    }
}

/// One of the eight caption windows of a service.
private final class Window {
    private static let maximumRowCount = 15
    private static let defaultPriority = 4
    /// The anchor range of relative positions.
    private static let relativeSize = 99
    /// The anchor ranges of absolute positions, for 16:9.
    private static let verticalSize = 74
    private static let horizontalSize = 209

    private enum Justification {
        static let left = 0
        static let right = 1
        static let center = 2
        static let full = 3
    }

    /// Window styles 1 to 7: justification, fill.
    private static let windowStyles: [(justification: Int, fill: Color)] = [
        (Justification.left, .solidBlack),
        (Justification.left, .transparent),
        (Justification.left, .solidBlack),
        (Justification.left, .solidBlack),
        (Justification.left, .transparent),
        (Justification.center, .solidBlack),
        (Justification.left, .solidBlack),
    ]
    /// Pen styles 1 to 7: background.
    private static let penStyleBackgrounds: [Color] = [
        .solidBlack, .solidBlack, .solidBlack, .solidBlack, .solidBlack, .transparent, .transparent,
    ]

    private struct Pen: Equatable {
        var italics = false
        var underline = false
        var foreground = Color.solidWhite
        var background = Color.solidBlack
    }

    private(set) var isDefined = false
    var isVisible = false
    private(set) var priority = Window.defaultPriority
    private var relativePositioning = false
    private var verticalAnchor = 0
    private var horizontalAnchor = 0
    private var anchorId = 0
    private var rowCount = Window.maximumRowCount
    private var justification = Justification.left
    private var windowStyle = 0
    private var penStyle = 0
    private var fillColor = Color.solidBlack
    private var pen = Pen()
    private var row = 0

    /// The rows above the current one.
    private var rolledUpRows: [AttributedString] = []
    /// The current row, with the pen of each character.
    private var currentRow: [(Character, Pen)] = []

    var isEmpty: Bool {
        !isDefined || (rolledUpRows.isEmpty && currentRow.isEmpty)
    }

    func reset() {
        clear()
        isDefined = false
        isVisible = false
        priority = Self.defaultPriority
        relativePositioning = false
        verticalAnchor = 0
        horizontalAnchor = 0
        anchorId = 0
        rowCount = Self.maximumRowCount
        justification = Justification.left
        windowStyle = 0
        penStyle = 0
        fillColor = .solidBlack
        pen = Pen()
    }

    func clear() {
        rolledUpRows.removeAll()
        currentRow.removeAll()
        row = 0
    }

    func define(
        isVisible: Bool,
        priority: Int,
        relativePositioning: Bool,
        verticalAnchor: Int,
        horizontalAnchor: Int,
        anchorId: Int,
        rowCount: Int,
        windowStyle: Int,
        penStyle: Int
    ) {
        isDefined = true
        self.isVisible = isVisible
        self.priority = priority
        self.relativePositioning = relativePositioning
        self.verticalAnchor = verticalAnchor
        self.horizontalAnchor = horizontalAnchor
        self.anchorId = anchorId

        // The count is one less than the rows.
        if self.rowCount != rowCount + 1 {
            self.rowCount = rowCount + 1
            trimRolledUpRows()
        }

        // Styles are 1-based; 0 keeps the current one.
        if windowStyle != 0, self.windowStyle != windowStyle {
            self.windowStyle = windowStyle
            let style = Self.windowStyles[windowStyle - 1]
            setWindowAttributes(fillColor: style.fill, justification: style.justification)
        }
        if penStyle != 0, self.penStyle != penStyle {
            self.penStyle = penStyle
            pen = Pen(background: Self.penStyleBackgrounds[penStyle - 1])
        }
    }

    func setWindowAttributes(fillColor: Color, justification: Int) {
        self.fillColor = fillColor
        self.justification = justification
    }

    func setPenAttributes(italics: Bool, underline: Bool) {
        pen.italics = italics
        pen.underline = underline
    }

    func setPenColor(foreground: Color, background: Color) {
        pen.foreground = foreground
        pen.background = background
    }

    /// Moves to `row`. Columns are not supported, so text of another row starts a new line, unless a carriage return
    /// already moved there.
    func setPenLocation(row: Int) {
        if self.row != row {
            append("\n")
        }
        self.row = row
    }

    func backspace() {
        if !currentRow.isEmpty {
            currentRow.removeLast()
        }
    }

    func append(_ character: Character) {
        guard character == "\n" else {
            currentRow.append((character, pen))
            return
        }
        rolledUpRows.append(attributedRow())
        currentRow.removeAll()
        row += 1
        trimRolledUpRows()
    }

    /// Keeps the rows the window has room for. Streams leave row lock off and still mean it, so it is not looked at.
    private func trimRolledUpRows() {
        while rolledUpRows.count >= min(rowCount, Self.maximumRowCount) {
            rolledUpRows.removeFirst()
        }
    }

    /// The current row: white text and a black background are the defaults, so not set.
    private func attributedRow() -> AttributedString {
        var result = AttributedString()
        var index = currentRow.startIndex
        while index < currentRow.endIndex {
            let pen = currentRow[index].1
            var end = index
            var text = ""
            while end < currentRow.endIndex, currentRow[end].1 == pen {
                text.append(currentRow[end].0)
                end += 1
            }
            var attributes = AttributeContainer()
            if pen.italics { attributes[CueTextAttributes.ItalicAttribute.self] = true }
            if pen.underline { attributes[CueTextAttributes.UnderlineAttribute.self] = true }
            if pen.foreground != .solidWhite {
                attributes[CueTextAttributes.ForegroundColorAttribute.self] = pen.foreground.cgColor
            }
            if pen.background != .solidBlack {
                attributes[CueTextAttributes.BackgroundColorAttribute.self] = pen.background.cgColor
            }
            result.append(AttributedString(text, attributes: attributes))
            index = end
        }
        return result
    }

    func build() -> Cue? {
        guard !isEmpty else { return nil }

        var text = AttributedString()
        for row in rolledUpRows {
            text.append(row)
            text.append(AttributedString("\n"))
        }
        text.append(attributedRow())

        let alignment: Cue.Alignment = switch justification {
        case Justification.right: .trailing
        case Justification.center: .center
        default: .leading
        }

        var position: CGFloat
        var line: CGFloat
        if relativePositioning {
            position = CGFloat(horizontalAnchor) / CGFloat(Self.relativeSize)
            line = CGFloat(verticalAnchor) / CGFloat(Self.relativeSize)
        } else {
            position = CGFloat(horizontalAnchor) / CGFloat(Self.horizontalSize)
            line = CGFloat(verticalAnchor) / CGFloat(Self.verticalSize)
        }
        // A margin at the edges of the screen.
        position = position * 0.9 + 0.05
        line = line * 0.9 + 0.05

        // The anchor point of the window, from 0 at the top left to 8 at the bottom right, row by row.
        func anchor(_ value: Int) -> Cue.Anchor {
            switch value {
            case 0: .start
            case 1: .middle
            default: .end
            }
        }

        let builder = Cue.Builder()
            .setText(text)
            .setTextAlignment(alignment)
            .setLine(.fraction(line))
            .setLineAnchor(anchor(anchorId / 3))
            .setPosition(position)
            .setPositionAnchor(anchor(anchorId % 3))
        if fillColor != .solidBlack {
            _ = builder.setWindowColor(fillColor.cgColor)
        }
        return builder.build()
    }
}
