//
//  ReadAhead.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import Foundation
import SEPlayerCommon

/// Controls how far data sources load ahead of what their consumer reads, and tells how much they hold there.
///
/// One instance follows the consumer from one data source to the next, as when it reopens at another position.
public final class ReadAhead: @unchecked Sendable {
    /// Whether loading may go on ahead of the reads, up to ``limit``. Without it a source loads only a little ahead.
    public var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set {
            if newValue != isEnabled {
                let state = newValue ? "on, up to \(Self.formatted(bytes: limit))" : "off"
                SELogger.debug(.readAhead, "Read-ahead \(state)")
            }
            update { $0._isEnabled = newValue }
        }
    }

    /// The most bytes loaded ahead of the furthest read.
    public var limit: Int {
        get { lock.withLock { _limit } }
        set {
            if newValue != limit {
                SELogger.debug(.readAhead, "Read-ahead limit \(Self.formatted(bytes: newValue))")
            }
            update { $0._limit = newValue }
        }
    }

    /// The bytes held without a gap after the furthest read, as last reported.
    public var availableBytes: Int {
        lock.withLock { _availableBytes }
    }

    /// The length of the resource, once a source knows it.
    public var resourceLength: Int? {
        lock.withLock { _resourceLength }
    }

    /// Whether the bytes held after the furthest read go on to the end of the resource: all of it is at hand, in
    /// memory or on storage.
    public var holdsToEnd: Bool {
        lock.withLock { _holdsToEnd }
    }

    /// Called, on no particular thread, when ``availableBytes`` changes.
    public var onAvailableBytesChange: (@Sendable () -> Void)? {
        get { lock.withLock { _onAvailableBytesChange } }
        set { lock.withLock { _onAvailableBytesChange = newValue } }
    }

    private let lock = UnfairLock()
    private var _isEnabled = false
    private var _limit: Int
    private var _availableBytes = 0
    private var _resourceLength: Int?
    private var _holdsToEnd = false
    private var _onAvailableBytesChange: (@Sendable () -> Void)?
    /// The sources loading for the consumer, told when the consumer changes what it allows.
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    public init(limit: Int = 32 * 1024 * 1024) { // 32 MB
        _limit = limit
    }

    // MARK: - Sources

    /// Calls `observer` whenever the consumer changes what it allows, until ``removeObserver(_:)``.
    func addObserver(_ owner: AnyObject, _ observer: @escaping () -> Void) {
        lock.withLock { observers[ObjectIdentifier(owner)] = observer }
    }

    func removeObserver(_ owner: AnyObject) {
        _ = lock.withLock { observers.removeValue(forKey: ObjectIdentifier(owner)) }
    }

    /// Reports what a source holds ahead of the furthest read.
    ///
    /// - Parameter holdsToEnd: Whether the held bytes go on to the end of the resource.
    func report(availableBytes: Int, resourceLength: Int?, holdsToEnd: Bool) {
        let onChange = lock.withLock { () -> (@Sendable () -> Void)? in
            let changed = _availableBytes != availableBytes || _resourceLength != resourceLength
                || _holdsToEnd != holdsToEnd
            _availableBytes = availableBytes
            _resourceLength = resourceLength ?? _resourceLength
            _holdsToEnd = holdsToEnd
            return changed ? _onAvailableBytesChange : nil
        }
        if onChange != nil {
            let heldBytes = Self.formatted(bytes: availableBytes)
            SELogger.verbose(.readAhead, "\(heldBytes) held ahead\(holdsToEnd ? ", to the end" : "")")
        }
        onChange?()
    }

    private func update(_ body: (ReadAhead) -> Void) {
        let observers = lock.withLock { () -> [() -> Void] in
            body(self)
            return Array(self.observers.values)
        }
        observers.forEach { $0() }
    }

    private static func formatted(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
