//
//  DiskCache.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import CryptoKit
import Foundation
import SEPlayerCommon

/// A cache of HTTP resources on storage, shared by data source factories.
///
/// Stores the resources whose data specs have ``DataSpec/Flags/storeOnDisk`` and a known length, up to ``maxSize``
/// bytes. When the cache is full, the least recently used entries that nobody reads are removed.
public final class DiskCache: @unchecked Sendable {
    /// What identifies a resource in the cache, unless its data spec has a ``DataSpec/key``.
    public enum KeyStrategy: Sendable {
        /// The whole URL.
        case url
        /// The URL without its query, for URLs that carry changing tokens.
        case urlWithoutQuery
        /// The path of the URL alone.
        case path
    }

    public static let defaultMaxSize = 50 * 1024 * 1024 // 50 MB
    public static let defaultMaxEntrySize = 40 * 1024 * 1024 // 40 MB

    public let directory: URL
    public let maxSize: Int
    public let maxEntrySize: Int
    public let keyStrategy: KeyStrategy

    /// The bytes the entries hold on storage.
    public var currentSize: Int {
        lock.withLock { totalSize }
    }

    /// Where files are written and read, one operation at a time.
    let ioQueue = DispatchQueue(label: "com.seplayer.diskcache", qos: .utility)

    private let lock = UnfairLock()

    // Guarded by `lock`.
    /// The entries on storage, by file name.
    private var records: [String: Record] = [:]
    /// The entries being read, by file name.
    private var openEntries: [String: OpenEntry] = [:]
    private var totalSize = 0

    /// - Parameters:
    ///   - directory: The folder of the cache, created if needed. `nil` for `SEPlayerMediaCache` in the caches
    ///     directory, which the system may empty when storage runs low.
    ///   - maxSize: The most bytes the cache holds.
    ///   - maxEntrySize: The most bytes one resource holds, at most `maxSize`.
    ///   - keyStrategy: What identifies a resource.
    public init(
        directory: URL? = nil,
        maxSize: Int = DiskCache.defaultMaxSize,
        maxEntrySize: Int = DiskCache.defaultMaxEntrySize,
        keyStrategy: KeyStrategy = .url
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.maxSize = max(0, maxSize)
        self.maxEntrySize = min(max(0, maxEntrySize), self.maxSize)
        self.keyStrategy = keyStrategy

        createDirectory()
        loadRecords()
        // The limits may be lower than when the entries were stored.
        lock.withLock { _ = removeEntries(toFit: 0, keeping: nil) }
    }

    /// Removes every entry nobody reads. The ones being read lose their blocks.
    public func removeAll() {
        let entriesBeingRead = lock.withLock {
            for name in records.keys where openEntries[name] == nil {
                removeFiles(name)
                totalSize -= records[name]?.size ?? 0
                records[name] = nil
            }

            return openEntries.values.map(\.entry)
        }
        entriesBeingRead.forEach { $0.invalidate() }
        SELogger.info(.diskCache, "Removed all entries")
    }

    // MARK: - Entries

    /// Whether the cache stores the bytes of `dataSpec`.
    static func canStore(_ dataSpec: DataSpec) -> Bool {
        dataSpec.flags.contains(.storeOnDisk) && dataSpec.httpMethod == "GET" && dataSpec.httpBody == nil
    }

    func key(for dataSpec: DataSpec) -> String {
        if let key = dataSpec.key {
            return key
        }

        switch keyStrategy {
        case .url:
            return dataSpec.url.absoluteString
        case .urlWithoutQuery:
            var components = URLComponents(url: dataSpec.url, resolvingAgainstBaseURL: true)
            components?.query = nil
            components?.fragment = nil
            return components?.url?.absoluteString ?? dataSpec.url.absoluteString
        case .path:
            return dataSpec.url.path
        }
    }

    /// The entry of `dataSpec`, with what is stored of it, for a resource that reads it until ``close(_:)``.
    func openEntry(for dataSpec: DataSpec) -> DiskCacheEntry {
        let key = key(for: dataSpec)
        let name = Self.fileName(for: key)
        return lock.withLock {
            records[name]?.lastUse = Date()
            if let openEntry = openEntries[name] {
                openEntries[name]?.readerCount += 1
                return openEntry.entry
            }

            let entry = DiskCacheEntry(
                cache: self,
                key: key,
                name: name,
                metadata: readMetadata(name: name, key: key)
            )
            openEntries[name] = OpenEntry(entry: entry, readerCount: 1)

            return entry
        }
    }

    /// Ends one resource's use of `entry`; it may be removed once nobody reads it.
    func close(_ entry: DiskCacheEntry) {
        let wasLastReader = lock.withLock {
            guard let openEntry = openEntries[entry.name] else { return false }
            guard openEntry.readerCount == 1 else {
                openEntries[entry.name]?.readerCount -= 1
                return false
            }

            openEntries[entry.name] = nil
            records[entry.name]?.lastUse = Date()
            return true
        }
        guard wasLastReader else { return }

        entry.saveMetadata()
        // Entries that were kept while read may be over the limit.
        lock.withLock { _ = removeEntries(toFit: 0, keeping: nil) }
    }

    /// Takes `bytes` more of the cache for the entry `name`, removing others if needed.
    ///
    /// - Returns: Whether they fit.
    func reserve(_ bytes: Int, for name: String) -> Bool {
        lock.withLock {
            guard removeEntries(toFit: bytes, keeping: name) else {
                return false
            }

            totalSize += bytes
            records[name, default: Record(size: 0, lastUse: Date())].size += bytes
            return true
        }
    }

    /// Gives back `bytes` the entry `name` no longer holds.
    func release(_ bytes: Int, for name: String) {
        lock.withLock {
            totalSize = max(0, totalSize - bytes)
            if let size = records[name]?.size {
                records[name]?.size = max(0, size - bytes)
            }
        }
    }

    /// Removes the least recently used entry nobody reads, for when the storage itself is full.
    func removeLeastRecentlyUsedEntry() {
        lock.withLock {
            guard let name = leastRecentlyUsedEntry(except: nil) else { return }

            removeEntry(name, reason: "storage is full")
        }
    }

    func dataURL(name: String) -> URL { directory.appendingPathComponent(name + ".data") }

    func metadataURL(name: String) -> URL { directory.appendingPathComponent(name + ".json") }
}

private extension DiskCache {
    struct Record {
        var size: Int
        var lastUse: Date
    }

    struct OpenEntry {
        let entry: DiskCacheEntry
        /// How many resources read the entry.
        var readerCount: Int
    }

    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SEPlayerMediaCache", isDirectory: true)
    }

    static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .prefix(20)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Removes entries nobody reads, the least recently used first, until `bytes` more fit. Must be called with the
    /// lock held.
    ///
    /// - Returns: Whether `bytes` more fit.
    func removeEntries(toFit bytes: Int, keeping name: String?) -> Bool {
        while totalSize + bytes > maxSize {
            guard let leastRecentlyUsed = leastRecentlyUsedEntry(except: name) else {
                return false
            }

            removeEntry(leastRecentlyUsed, reason: "the cache is over \(maxSize / 1024 / 1024) MB")
        }

        return true
    }

    /// The least recently used entry that nobody reads. Must be called with the lock held.
    func leastRecentlyUsedEntry(except name: String?) -> String? {
        records
            .filter { $0.key != name && openEntries[$0.key] == nil }
            .min { $0.value.lastUse < $1.value.lastUse }?
            .key
    }

    /// Must be called with the lock held.
    func removeEntry(_ name: String, reason: String) {
        let size = records[name]?.size ?? 0
        totalSize = max(0, totalSize - size)
        records[name] = nil
        removeFiles(name)
        SELogger.debug(.diskCache, "Removed an entry of \(size / 1024) KB: \(reason)")
    }

    func removeFiles(_ name: String) {
        let urls = [dataURL(name: name), metadataURL(name: name)]
        ioQueue.async {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    func createDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try? directory.setResourceValues(values)
    }

    /// Finds the entries on storage: their sizes from the data files, their last use from the metadata files.
    func loadRecords() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        )

        var sizes: [String: Int] = [:]
        var dates: [String: Date] = [:]
        for file in files ?? [] {
            let name = file.deletingPathExtension().lastPathComponent
            let values = try? file.resourceValues(forKeys: keys)

            switch file.pathExtension {
            case "data":
                sizes[name] = values?.fileSize ?? 0
            case "json":
                dates[name] = values?.contentModificationDate ?? .distantPast
            default:
                break
            }
        }

        lock.withLock {
            for (name, size) in sizes {
                guard let date = dates[name] else {
                    // A data file can't be read without its metadata.
                    removeFiles(name)
                    continue
                }

                records[name] = Record(size: size, lastUse: date)
                totalSize += size
            }

            for name in dates.keys where sizes[name] == nil {
                removeFiles(name)
            }
        }

        let sizeInKB = totalSize / 1024
        let maxSizeInKB = maxSize / 1024
        SELogger.info(.diskCache, "\(records.count) entries, \(sizeInKB) KB of \(maxSizeInKB) KB, in \(directory.path)")
    }

    /// Must be called with the lock held.
    func readMetadata(name: String, key: String) -> DiskCacheEntry.Metadata? {
        guard records[name] != nil else { return nil }
        guard let data = try? Data(contentsOf: metadataURL(name: name)) else {
            return nil
        }
        guard let metadata = try? JSONDecoder().decode(DiskCacheEntry.Metadata.self, from: data) else {
            return nil
        }
        guard metadata.version == DiskCacheEntry.Metadata.currentVersion, metadata.key == key else {
            return nil
        }

        return metadata
    }
}
