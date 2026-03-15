//
//  DataSpec.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public struct DataSpec {
    private(set) public var url: URL
    private(set) public var offset: Int
    private(set) public var length: Int
    private(set) public var key: String?
    private(set) public var httpRequestHeaders: [String: String]

    public static func spec(from url: URL) -> DataSpec {
        return .init(url: url, offset: 0, length: 0, key: nil, httpRequestHeaders: [:])
    }

    public static func spec(from url: URL, offset: Int, length: Int) -> DataSpec {
        return .init(url: url, offset: offset, length: length, key: nil, httpRequestHeaders: [:])
    }

    public func offset(_ offset: Int) -> DataSpec {
        var currentSpec = self
        currentSpec.offset = offset
        return currentSpec
    }

    public func length(_ length: Int) -> DataSpec {
        var currentSpec = self
        currentSpec.length = length
        return currentSpec
    }
}

public extension DataSpec {
    var range: NSRange {
        NSRange(location: offset, length: length)
    }

    func createURLRequest() -> URLRequest {
        var request = URLRequest(url: url)

        if offset > 0 || length > 0 {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            var rangeString = "bytes=\(range.lowerBound)-"
            if length > 0 {
                rangeString.append("\(range.upperBound)")
            }
            request.addValue(rangeString, forHTTPHeaderField: "Range")
        }

        return request
    }
}
