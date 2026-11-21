//
//  IcyHeaders.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import SEPlayerCommon

/// The ICY headers of a response: what an internet radio server says about its stream.
public struct IcyHeaders: Metadata.Entry {
    /// The request header that asks a server to put ICY metadata in the stream.
    public static let requestHeaderEnableMetadataName = "Icy-MetaData"
    public static let requestHeaderEnableMetadataValue = "1"

    /// The bitrate in bits per second (`icy-br` is in kbit/s).
    public let bitrate: Int?
    /// `icy-genre`.
    public let genre: String?
    /// `icy-name`: the station.
    public let name: String?
    /// `icy-url`.
    public let url: String?
    /// `icy-pub`: whether the stream is listed publicly.
    public let isPublic: Bool
    /// `icy-metaint`: the number of stream bytes between two metadata blocks, or `nil` if the stream has none.
    public let metadataInterval: Int?

    public var description: String {
        "IcyHeaders: name=\"\(name ?? "nil")\", genre=\"\(genre ?? "nil")\", bitrate=\(bitrate.map(String.init) ?? "nil"), "
            + "metadataInterval=\(metadataInterval.map(String.init) ?? "nil")"
    }

    public init(bitrate: Int?, genre: String?, name: String?, url: String?, isPublic: Bool, metadataInterval: Int?) {
        self.bitrate = bitrate
        self.genre = genre
        self.name = name
        self.url = url
        self.isPublic = isPublic
        self.metadataInterval = metadataInterval
    }

    /// The ICY headers of `responseHeaders`, whose names are compared without case, or `nil` if there are none.
    public static func parse(responseHeaders: [AnyHashable: Any]) -> IcyHeaders? {
        var headers = [String: String]()
        for (key, value) in responseHeaders {
            guard let key = key as? String else { continue }
            headers[key.lowercased()] = (value as? String) ?? (value as? [String])?.first
        }

        var icyHeadersPresent = false
        var bitrate: Int?
        if let header = headers["icy-br"] {
            if let kilobits = Int(header.trimmingCharacters(in: .whitespaces)), kilobits > 0 {
                bitrate = kilobits * 1000
                icyHeadersPresent = true
            } else {
                SELogger.warning(.metadata, "Invalid bitrate header: \(header)")
            }
        }
        let genre = headers["icy-genre"]
        let name = headers["icy-name"]
        let url = headers["icy-url"]
        if genre != nil || name != nil || url != nil || headers["icy-pub"] != nil {
            icyHeadersPresent = true
        }
        var metadataInterval: Int?
        if let header = headers["icy-metaint"] {
            if let interval = Int(header.trimmingCharacters(in: .whitespaces)), interval > 0 {
                metadataInterval = interval
                icyHeadersPresent = true
            } else {
                SELogger.warning(.metadata, "Invalid metadata interval: \(header)")
            }
        }

        guard icyHeadersPresent else { return nil }
        return IcyHeaders(
            bitrate: bitrate,
            genre: genre,
            name: name,
            url: url,
            isPublic: headers["icy-pub"] == "1",
            metadataInterval: metadataInterval
        )
    }

    public func populateMediaMetadata(_ builder: MediaMetadata.Builder) {
        if let name {
            builder.setStation(name)
        }
        if let genre {
            builder.setGenre(genre)
        }
    }
}
