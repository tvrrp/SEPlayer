//
//  DataSpec.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.datasource.DataSpec
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import Foundation

public struct DataSpec {
    public let url: URL
    public let urlPositionOffset: Int
    public let httpMethod: String
    public let httpBody: Data?
    public let allHTTPHeaderFields: [String: String]
    public let position: Int
    public let length: Int?
    public let key: String?
    public let flags: Flags
    public let customData: Any?

    fileprivate init(builder: Builder) {
        self.url = builder.url
        self.urlPositionOffset = builder.urlPositionOffset
        self.httpMethod = builder.httpMethod
        self.httpBody = builder.httpBody
        self.allHTTPHeaderFields = builder.allHTTPHeaderFields
        self.position = builder.position
        self.length = builder.length
        self.key = builder.key
        self.flags = builder.flags
        self.customData = builder.customData
    }

    public func buildUpon() -> Builder {
        Builder(dataSpec: self)
    }
}

extension DataSpec: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(urlPositionOffset)
        hasher.combine(httpMethod)
        hasher.combine(httpBody)
        hasher.combine(allHTTPHeaderFields)
        hasher.combine(position)
        hasher.combine(length)
        hasher.combine(key)
        hasher.combine(flags)
    }

    public static func == (lhs: DataSpec, rhs: DataSpec) -> Bool {
        lhs.url == rhs.url
            && lhs.urlPositionOffset == rhs.urlPositionOffset
            && lhs.httpMethod == rhs.httpMethod
            && lhs.httpBody == rhs.httpBody
            && lhs.allHTTPHeaderFields == rhs.allHTTPHeaderFields
            && lhs.position == rhs.position
            && lhs.length == rhs.length
            && lhs.key == rhs.key
            && lhs.flags == rhs.flags
            && lhs.urlPositionOffset == rhs.urlPositionOffset
            && lhs.customData == nil && rhs.customData == nil
    }
}

public extension DataSpec {
    var range: NSRange {
        NSRange(location: position, length: length!)
    }

    var range2: Range<Int> {
        if let length {
            position ..< (position + length)
        } else {
            position ..< position
        }
    }

    func createURLRequest() -> URLRequest {
        var request = URLRequest(url: url)
        // Idle time, not total time: a request that stops answering fails after this and the
        // loader retries it, instead of waiting out the 60-second default.
        request.timeoutInterval = 8

        if position > 0 || length != nil {
            // `Range` is inclusive on both ends, so the last byte is position + length - 1.
            var rangeString = "bytes=\(position)-"
            if let length, length > 0 {
                rangeString.append("\(position + length - 1)")
            }

            request.addValue(rangeString, forHTTPHeaderField: "Range")
        }

        for (key, value) in allHTTPHeaderFields {
            request.addValue(value, forHTTPHeaderField: key)
        }

        return request
    }

    struct Flags: OptionSet, Hashable {
        public var rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let allowGzip = Flags(rawValue: 1)
        public static let dontCacheIfLengthUnknown = Flags(rawValue: 1 << 1)
        public static let allowCacheFragmentation = Flags(rawValue: 1 << 2)
        /// The server may hold the response, or send it as fast as it makes it, rather than as fast as the network
        /// allows, as for a part an HLS preload hint announces or a blocking playlist reload: the transfer doesn't
        /// measure the network.
        public static let mightNotUseFullNetworkSpeed = Flags(rawValue: 1 << 3)
        /// The loaded bytes may be kept after the data source closes, for another to read them again, as after a
        /// seek. Only for resources that don't change, unlike a live playlist.
        public static let keepLoadedBytes = Flags(rawValue: 1 << 4)
        /// The loaded bytes may be kept on storage, by the ``DiskCache`` of the data source factory, for playing the
        /// resource again without the network. Only for resources that don't change and aren't secret, unlike a live
        /// playlist or a key.
        public static let storeOnDisk = Flags(rawValue: 1 << 5)
    }

    struct Builder {
        fileprivate var url: URL
        fileprivate var urlPositionOffset: Int = 0
        fileprivate var httpMethod: String = "GET"
        fileprivate var httpBody: Data?
        fileprivate var allHTTPHeaderFields = [String: String]()
        fileprivate var position: Int = 0
        fileprivate var length: Int?
        fileprivate var key: String?
        fileprivate var flags = Flags()
        fileprivate var customData: Any?

        public init(url: URL) {
            self.url = url
        }

        fileprivate init(dataSpec: DataSpec) {
            self.url = dataSpec.url
            self.urlPositionOffset = dataSpec.urlPositionOffset
            self.httpMethod = dataSpec.httpMethod
            self.httpBody = dataSpec.httpBody
            self.allHTTPHeaderFields = dataSpec.allHTTPHeaderFields
            self.position = dataSpec.position
            self.length = dataSpec.length
            self.key = dataSpec.key
            self.flags = dataSpec.flags
            self.customData = dataSpec.customData
        }

        @discardableResult
        public func setUrl(_ url: URL) -> Builder {
            var mutSelf = self
            mutSelf.url = url
            return mutSelf
        }

        @discardableResult
        public func setUrlPositionOffset(_ offset: Int) -> Builder {
            var mutSelf = self
            mutSelf.urlPositionOffset = offset
            return mutSelf
        }

        @discardableResult
        public func setHttpMethod(_ method: String) -> Builder {
            var mutSelf = self
            mutSelf.httpMethod = method
            return mutSelf
        }

        @discardableResult
        public func setHttpBody(_ body: Data?) -> Builder {
            var mutSelf = self
            mutSelf.httpBody = body
            return mutSelf
        }

        @discardableResult
        public func setAllHTTPHeaderFields(_ headers: [String: String]) -> Builder {
            var mutSelf = self
            mutSelf.allHTTPHeaderFields = headers
            return mutSelf
        }

        @discardableResult
        public func addHTTPHeaderField(key: String, value: String) -> Builder {
            var mutSelf = self
            mutSelf.allHTTPHeaderFields[key] = value
            return mutSelf
        }

        @discardableResult
        public func setPosition(_ position: Int) -> Builder {
            var mutSelf = self
            mutSelf.position = position
            return mutSelf
        }

        @discardableResult
        public func setLength(_ length: Int?) -> Builder {
            var mutSelf = self
            mutSelf.length = length
            return mutSelf
        }

        @discardableResult
        public func setKey(_ key: String?) -> Builder {
            var mutSelf = self
            mutSelf.key = key
            return mutSelf
        }

        @discardableResult
        public func setFlags(_ flags: Flags) -> Builder {
            var mutSelf = self
            mutSelf.flags = flags
            return mutSelf
        }

        @discardableResult
        public func setCustomData(_ customData: Any?) -> Builder {
            var mutSelf = self
            mutSelf.customData = customData
            return mutSelf
        }

        public func build() -> DataSpec {
            DataSpec(builder: self)
        }
    }
}
