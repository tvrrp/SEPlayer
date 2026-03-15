//
//  Metadata.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//

public struct Metadata {
    public protocol Entry: Hashable {
        var wrappedMetadataFormat: Format? { get }
        var wrappedMetadataBytes: ByteBuffer? { get }
        func populateMediaMetadata(builder: MediaMetadata.Builder)
        func isEqual(to other: any Entry) -> Bool
    }

    public let presentationTimeUs: Int64
    private let entries: [any Entry]

    public init(
        presentationTimeUs: Int64 = .timeUnset,
        entries: [any Entry] = []
    ) {
        self.presentationTimeUs = presentationTimeUs
        self.entries = entries
    }

    public func copyWithAppendedEntriesFrom(other medatada: Metadata?) -> Metadata {
        guard let medatada else { return self }

        return copyWithAppendedEntries(medatada.entries)
    }

    public func copyWithAppendedEntries(_ entriesToAppend: [any Entry]) -> Metadata {
        guard !entriesToAppend.isEmpty else {
            return self
        }

        return Metadata(presentationTimeUs: presentationTimeUs, entries: entries + entriesToAppend)
    }

    public func copyWithPresentationTimeUs(_ presentationTimeUs: Int64) -> Metadata {
        if self.presentationTimeUs == presentationTimeUs {
            return self
        }

        return Metadata(presentationTimeUs: presentationTimeUs, entries: entries)
    }
}

extension Metadata: Hashable {
    public func hash(into hasher: inout Hasher) {
        entries.forEach { $0.hash(into: &hasher) }
        hasher.combine(presentationTimeUs)
    }

    public static func == (lhs: Metadata, rhs: Metadata) -> Bool {
        lhs.elementsEqual(rhs, by: { $0.isEqual(to: $1) }) && rhs.presentationTimeUs == rhs.presentationTimeUs
    }
}

extension Metadata: Collection {
    public typealias Index = Array<any Entry>.Index
    public typealias Element = Entry
    public var startIndex: Int { entries.startIndex }
    public var endIndex: Int { entries.endIndex }

    public subscript(index: Index) -> Iterator.Element {
        get { return entries[index] }
    }

    public func index(after i: Index) -> Index {
        return entries.index(after: i)
    }
}

public extension Metadata.Entry {
    var wrappedMetadataFormat: Format? { nil }
    var wrappedMetadataBytes: ByteBuffer? { nil }
    func populateMediaMetadata(builder: MediaMetadata.Builder) {}
}
