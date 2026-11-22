//
//  WebvttParserUtil.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.webvtt.WebvttParserUtil
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Utility methods for parsing WebVTT data.
public enum WebvttParserUtil {
    /// The timescale WebVTT times are given in.
    static let timescale: CMTimeScale = 1_000_000

    /// Reads the WebVTT header line, and throws if it isn't one.
    static func validateWebvttHeaderLine(_ reader: inout WebvttLineReader) throws {
        guard let line = reader.readLine(), isWebvttHeaderLine(line) else {
            throw ParserError.createForMalformedDataOfUnknownType(message: "Expected WEBVTT. Got \(reader.lastLine ?? "nil")")
        }
    }

    /// Whether the line is a WebVTT header line: `WEBVTT`, optionally after a byte order mark, followed by the end of
    /// the line or by a space or a tab and more text.
    public static func isWebvttHeaderLine(_ line: String) -> Bool {
        var line = Substring(line)
        if line.first == "\u{FEFF}" { line = line.dropFirst() }
        guard line.hasPrefix("WEBVTT") else { return false }
        let rest = line.dropFirst(6)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    /// Parses a WebVTT timestamp: `[hh:]mm:ss.ttt`.
    public static func parseTimestamp(_ timestamp: some StringProtocol) throws -> CMTime {
        let parts = timestamp.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var value: Int64 = 0
        for subpart in parts[0].split(separator: ":", omittingEmptySubsequences: false) {
            guard let number = Int64(subpart) else {
                throw invalidNumber(timestamp)
            }
            value = value * 60 + number
        }
        value *= 1000
        if parts.count == 2 {
            guard let milliseconds = Int64(parts[1]) else {
                throw invalidNumber(timestamp)
            }
            value += milliseconds
        }
        return CMTime(value: value * 1000, timescale: timescale)
    }

    /// Parses a percentage string, `"57%"`, as a fraction, `0.57`.
    static func parsePercentage(_ string: some StringProtocol) throws -> CGFloat {
        guard string.hasSuffix("%"), let value = Double(string.dropLast()) else {
            throw ParserError.createForMalformedDataOfUnknownType(message: "Percentages must end with %: \(string)")
        }
        return CGFloat(value / 100)
    }

    /// Reads lines up to the next cue header and parses it. Comment blocks on the way are skipped.
    ///
    /// - Returns: The start and end times and the settings of the cue, or `nil` if there is no other cue.
    static func findNextCueHeader(_ reader: inout WebvttLineReader) -> WebvttCueParser.CueHeader? {
        while let line = reader.readLine() {
            if isCommentHeader(line) {
                while let line = reader.readLine(), !line.isEmpty {}
            } else if let header = WebvttCueParser.CueHeader(line: line) {
                return header
            }
        }
        return nil
    }

    /// Whether the line starts a comment block: `NOTE`, followed by the end of the line or a space or a tab.
    static func isCommentHeader(_ line: String) -> Bool {
        guard line.hasPrefix("NOTE") else { return false }
        let rest = line.dropFirst(4)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    private static func invalidNumber(_ timestamp: some StringProtocol) -> Error {
        ParserError.createForMalformedDataOfUnknownType(message: "Invalid WebVTT timestamp: \(timestamp)")
    }
}

/// Reads WebVTT data line by line. Lines end with LF, CR or CRLF.
struct WebvttLineReader {
    private let lines: [String]
    private(set) var position = 0

    /// The last line read, for error messages.
    var lastLine: String? { position > 0 && position <= lines.count ? lines[position - 1] : nil }

    init(text: String) {
        var lines: [String] = []
        var current = ""
        var iterator = text.unicodeScalars.makeIterator()
        var pendingCarriageReturn = false
        while let scalar = iterator.next() {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if scalar == "\n" { continue }
            }
            switch scalar {
            case "\r":
                lines.append(current)
                current = ""
                pendingCarriageReturn = true
            case "\n":
                lines.append(current)
                current = ""
            default:
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(current) }
        self.lines = lines
    }

    /// Decodes UTF-8 data, without a byte order mark.
    init(data: Data) throws {
        let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
        let textStart = data.starts(with: byteOrderMark) ? data.startIndex + byteOrderMark.count : data.startIndex
        guard let text = String(data: data[textStart...], encoding: .utf8) else {
            throw ParserError.createForMalformedDataOfUnknownType(message: "WebVTT data isn't UTF-8.")
        }
        self.init(text: text)
    }

    /// Reads the next line, or returns `nil` at the end of the data.
    mutating func readLine() -> String? {
        guard position < lines.count else {
            position = lines.count + 1
            return nil
        }
        defer { position += 1 }
        return lines[position]
    }

    /// Returns the next line without reading it.
    func peekLine() -> String? {
        position < lines.count ? lines[position] : nil
    }

    /// Goes back to a position from ``position``.
    mutating func setPosition(_ position: Int) {
        self.position = min(position, lines.count)
    }
}
