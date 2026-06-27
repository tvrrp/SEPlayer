//
//  FetchExecutor.swift
//  SEPlayer
//
//  Created by tvrrp on 21.06.2026.
//

import Foundation
import SEPlayerCommon
import Playgrounds

public final class FetchExecutor: @unchecked Sendable {
    var runningFetches: [Fetch] {
        assert(queue.isCurrent())
        return Array(fetches.values)
    }

    private let queue: Queue
    private let dataSpec: DataSpec
    private let factory: HTTPTransportFactory
    private let eventSink: @Sendable (UUID, TransportEvent) -> Void

    private(set) var fetches: [UUID: Fetch] = [:]

    init(
        queue: Queue,
        dataSpec: DataSpec,
        factory: HTTPTransportFactory,
        eventSink: @escaping @Sendable (UUID, TransportEvent) -> Void
    ) {
        self.queue = queue
        self.dataSpec = dataSpec
        self.factory = factory
        self.eventSink = eventSink
    }

    func ensureFetch(covering range: Range<Int>, policy: FetchPolicy) throws {
        assert(queue.isCurrent())
        if findAttachable(for: range) != nil { return }
        let planned = plannedRange(for: range, policy: policy)
        guard !planned.isEmpty else { throw IOError(message: nil, cause: nil) }
        startFetch(range: planned)
    }

    func fetch(byID id: UUID) -> Fetch? {
        assert(queue.isCurrent())
        return fetches[id]
    }

    func cancel(id: UUID) {
        assert(queue.isCurrent())
        guard let fetch = fetches.removeValue(forKey: id) else { return }
        fetch.transport.cancel()
    }

    func cancelAll() {
        assert(queue.isCurrent())
        for fetch in fetches.values { fetch.transport.cancel() }
        fetches.removeAll()
    }

    func recordBytesReceived(fetchID: UUID, count: Int) {
        assert(queue.isCurrent())
        guard let fetch = fetches[fetchID] else { return }
        fetch.bytesReceived += count
        fetch.lastBytesAt = DispatchTime.now()
    }

    func recordStatusChange(fetchID: UUID, status: TransportStatus) {
        assert(queue.isCurrent())
        guard let fetch = fetches[fetchID] else { return }
        fetch.status = status
        switch status {
        case .completed, .failed, .cancelled:
            fetches.removeValue(forKey: fetchID)
        case .pending, .running:
            break
        }
    }

    private func findAttachable(for range: Range<Int>) -> Fetch? {
        for fetch in fetches.values where fetch.range.contains(range) {
            // TODO: integrate download-speed-based stall prediction here.
            return fetch
        }
        return nil
    }

    private func plannedRange(for range: Range<Int>, policy: FetchPolicy) -> Range<Int> {
        let upper = max(range.upperBound, policy.fetchUpTo)
        return range.lowerBound..<upper
    }

    private func startFetch(range: Range<Int>) {
        let id = UUID()
        let sink = self.eventSink
        let transport = factory.makeTransport(
            dataSpec: dataSpec,
            rangeID: id,
            eventSink: { event in sink(id, event) }
        )
        let fetch = Fetch(id: id, range: range, transport: transport)
        fetches[id] = fetch
        transport.start()
    }
}

extension FetchExecutor {
    public final class Fetch {
        public let id: UUID
        public let range: Range<Int>
        public let transport: HTTPTransport
        public let startedAt: DispatchTime
        public fileprivate(set) var status: TransportStatus
        public fileprivate(set) var bytesReceived: Int
        public fileprivate(set) var lastBytesAt: DispatchTime

        init(id: UUID, range: Range<Int>, transport: HTTPTransport) {
            self.id = id
            self.range = range
            self.transport = transport
            let now = DispatchTime.now()
            self.startedAt = now
            self.lastBytesAt = now
            self.status = .pending
            self.bytesReceived = 0
        }
    }
}
