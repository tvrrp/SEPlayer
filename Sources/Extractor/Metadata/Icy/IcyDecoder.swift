//
//  IcyDecoder.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import Foundation
import SEPlayerCommon

/// Decodes ICY stream metadata: `StreamTitle='…';StreamUrl='…';`.
public struct IcyDecoder: MetadataDecoder {
    public init() {}

    public func decode(_ data: BlockBufferReader) -> Metadata? {
        guard let rawMetadata = try? data.getData(at: data.readerIndex, length: data.readableBytes) else { return nil }
        // The ICY protocol names no character encoding and has no way to send one: UTF-8 is tried first, then
        // ISO-8859-1, which any bytes are.
        let string = data.getString(at: data.readerIndex, length: data.readableBytes, encoding: .utf8)
            ?? data.getString(at: data.readerIndex, length: data.readableBytes, encoding: .isoLatin1)
            ?? ""

        var title: String?
        var url: String?
        for (key, value) in Self.elements(of: string) {
            switch key.lowercased() {
            case "streamtitle": title = value
            case "streamurl": url = value
            default: break
            }
        }
        return Metadata(IcyInfo(rawMetadata: rawMetadata, title: title, url: url))
    }

    /// The `key='value';` pairs of `string`. A value may contain quotes; it ends at the first `';`.
    private static func elements(of string: String) -> [(String, String)] {
        var elements = [(String, String)]()
        var remainder = Substring(string)
        while let separator = remainder.range(of: "='") {
            let key = remainder[..<separator.lowerBound]
            let valueStart = separator.upperBound
            guard let end = remainder.range(of: "';", range: valueStart ..< remainder.endIndex) else { break }
            if !key.isEmpty {
                elements.append((String(key), String(remainder[valueStart ..< end.lowerBound])))
            }
            remainder = remainder[end.upperBound...]
        }
        return elements
    }
}
