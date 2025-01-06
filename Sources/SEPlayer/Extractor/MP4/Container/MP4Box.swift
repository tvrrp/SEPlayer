//
//  MP4Box.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

enum MP4Box {
    protocol Box {
        var type: BoxType? { get }
    }
}

struct LeafBox: MP4Box.Box {
    let type: MP4Box.BoxType?
    let data: ByteBuffer

    init(type: UInt32, data: ByteBuffer) {
        self.type = MP4Box.BoxType(rawValue: type)
        self.data = data
    }
}

struct ContainerBox: MP4Box.Box {
    let type: MP4Box.BoxType?
    let endPosition: Int

    var leafChildren: [LeafBox]
    var containerChildren: [ContainerBox]

    init(type: UInt32, endPosition: Int) {
        self.type = MP4Box.BoxType(rawValue: type)
        self.endPosition = endPosition
        self.leafChildren = .init()
        self.containerChildren = .init()
    }

    mutating func add(_ box: LeafBox) {
        leafChildren.append(box)
    }

    mutating func add(_ box: ContainerBox) {
        containerChildren.append(box)
    }

    func getLeafBoxOfType(type: MP4Box.BoxType) -> LeafBox? {
        leafChildren.first(where: { $0.type == type })
    }

    func getContainerBoxOfType(type: MP4Box.BoxType) -> ContainerBox? {
        containerChildren.first(where: { $0.type == type })
    }
}

extension MP4Box {
    static let boxSize: Int = 4
    static let headerSize: Int = 8
    static let fullHeaderSize: Int = 12
    static let longHeaderSize: Int = 16
    static let definesLargeSize: Int = 1
    static let extendsToEndSize: Int = 0
}
