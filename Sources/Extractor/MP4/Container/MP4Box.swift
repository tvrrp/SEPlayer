//
//  MP4Box.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import SEPlayerCommon

public enum MP4Box {
    public protocol Box {
        var type: BoxType? { get }
    }
}

public struct LeafBox: MP4Box.Box {
    public let type: MP4Box.BoxType?
    public let data: BlockBufferReader

    public init(type: UInt32, data: BlockBufferReader) {
        self.type = MP4Box.BoxType(rawValue: type)
        self.data = data
    }
}

public struct ContainerBox: MP4Box.Box {
    public let type: MP4Box.BoxType?
    public let endPosition: Int

    public var leafChildren: [LeafBox]
    public var containerChildren: [ContainerBox]

    public init(type: UInt32, endPosition: Int) {
        self.type = MP4Box.BoxType(rawValue: type)
        self.endPosition = endPosition
        self.leafChildren = .init()
        self.containerChildren = .init()
    }

    public mutating func add(_ box: LeafBox) {
        leafChildren.append(box)
    }

    public mutating func add(_ box: ContainerBox) {
        containerChildren.append(box)
    }

    public func getLeafBoxOfType(type: MP4Box.BoxType) -> LeafBox? {
        leafChildren.first(where: { $0.type == type })
    }

    public func getContainerBoxOfType(type: MP4Box.BoxType) -> ContainerBox? {
        containerChildren.first(where: { $0.type == type })
    }
}

public extension MP4Box {
    static let boxSize: Int = 4
    static let headerSize: Int = 8
    static let fullHeaderSize: Int = 12
    static let longHeaderSize: Int = 16
    static let definesLargeSize: Int = 1
    static let extendsToEndSize: Int = 0
}
