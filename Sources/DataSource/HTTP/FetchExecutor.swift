//
//  FetchExecutor.swift
//  SEPlayer
//
//  Created by tvrrp on 21.06.2026.
//

import Foundation
import SEPlayerCommon

public protocol FetchExecutorDelegate: AnyObject {
    func runEventStream(_ stream: AsyncStream<TransportStatus>, fetchId: UUID)
    func runSessionStream(_ stream: AsyncStream<TransportEvent>, fetchId: UUID)
}

public final class FetchExecutor: @unchecked Sendable {
    public weak var delegate: FetchExecutorDelegate?

    private let queue: any Queue
    private let factory: any HTTPTransportFactory

    private var sourceLenght: Int?
    private var fetches = [UUID: FetchesStorage]()

    init(
        queue: any Queue,
        factory: any HTTPTransportFactory,
    ) {
        self.queue = queue
        self.factory = factory
    }

    @discardableResult
    func register(dataSpec: DataSpec) -> Fetch2 {
        let fetchesForAttaching = fetches.values.filter { $0.canHandle(spec: dataSpec) }

        guard !fetchesForAttaching.isEmpty else {
            let storage = createNewFetchRequest(dataSpec: dataSpec)
            let fetch = Fetch2(
                parentId: storage.id,
                readOffset: dataSpec.position,
                readLenght: dataSpec.length
            )
            storage.registerFetch(fetch: fetch)
            fetches[storage.id] = storage
            return fetch
        }

        let fetchForAttaching: FetchesStorage

        if fetchesForAttaching.count == 1 {
            fetchForAttaching = fetchesForAttaching[0]
        } else {
            fetchForAttaching = fetchesForAttaching.min(by: {
                abs($0.offset - dataSpec.position) < abs($1.offset - dataSpec.position)
            }) ?? fetchesForAttaching[0]
        }

//        let fetch = Fetch2(
//            parentId: fetchForAttaching.id,
//            readOffset: dataSpec.position,
//            readLenght: dataSpec.length
//        )
//        fetchForAttaching.registerFetch(fetch: fetch)
//        return fetch

        switch fetchForAttaching.lenght {
        case .none:
            // HTTP Response without Content-Lenght header or Chunked transfer encoding
            let fetch = Fetch2(
                parentId: fetchForAttaching.id,
                readOffset: dataSpec.position,
                readLenght: dataSpec.length
            )
            fetchForAttaching.registerFetch(fetch: fetch)
            return fetch
        case .some(_):
            if abs(dataSpec.range2.lowerBound - fetchForAttaching.loadingPosition) > 50000 {
                fallthrough
            }

            // TODO: calculate based on network speed
            let fetch = Fetch2(
                parentId: fetchForAttaching.id,
                readOffset: dataSpec.position,
                readLenght: dataSpec.length
            )
            fetchForAttaching.registerFetch(fetch: fetch)
            return fetch
        default:
            let storage = createNewFetchRequest(
                dataSpec: dataSpec.buildUpon().setLength(nil).build()
            )
            let fetch = Fetch2(
                parentId: storage.id,
                readOffset: dataSpec.position,
                readLenght: dataSpec.length
            )
            storage.registerFetch(fetch: fetch)
            fetches[storage.id] = storage
//            fetchForAttaching.bytesToLoadMax = dataSpec.range2.upperBound
            return fetch
        }
    }

    func recordBytesReceived(fetchID: UUID, count: Int) {
        guard let storage = fetches[fetchID] else { return }
        storage.registerBytesReceived(count: count)
    }

    func recordStatusChange(fetchID: UUID, status: TransportStatus) {
        guard let storage = fetches[fetchID] else { return }

        switch status {
        case .pending:
            return
        case let .running(readLenght):
            storage.lenght = readLenght

            let fetches = storage.runningFetches.values.filter { $0.readRange.isEmpty }
            fetches.forEach {
                $0.continuation?.resume()
                $0.continuation = nil
                storage.runningFetches.removeValue(forKey: $0.requestId)
            }

            return
        case .completed:
            storage.finishAll()
            fetches.removeValue(forKey: storage.id)
        case .cancelled:
            storage.finishAll()
            fetches.removeValue(forKey: storage.id)
        case let .failed(error):
            storage.finishAll(with: error)
            fetches.removeValue(forKey: storage.id)
        }
    }

    func cancel(fetch: Fetch2) {
        guard let storage = fetches[fetch.parentId] else {
            return
        }

        fetch.continuation?.resume(throwing: CancellationError())
        fetch.continuation = nil
        storage.runningFetches.removeValue(forKey: fetch.requestId)
    }

    func cancelAll() {
        fetches.values.forEach { $0.cancelAll() }
        fetches.removeAll()
    }

    private func createNewFetchRequest(dataSpec: DataSpec) -> FetchesStorage {
        let fetchId = UUID()
        let transport = factory.makeTransport(dataSpec: dataSpec, rangeID: fetchId)
        let (event, session) = transport.start()
        delegate?.runEventStream(event, fetchId: transport.rangeID)
        delegate?.runSessionStream(session, fetchId: transport.rangeID)

        let defaultCanclBytes = Int(getpagesize() * 5)
        return FetchesStorage(
            id: fetchId,
            offset: dataSpec.position,
            lenght: dataSpec.length,
            transport: transport,
            bytesDownloadedForTaskCancellation: defaultCanclBytes
        )
    }
}

extension FetchExecutor {
    final class Fetch2 {
        let parentId: UUID
        let requestId: UUID
        let readRange: Range<Int>
        fileprivate var continuation: CheckedContinuation<(), any Error>?

        init(parentId: UUID, readOffset: Int, readLenght: Int?) {
            self.parentId = parentId
            self.readRange = if let readLenght {
                readOffset..<(readOffset + readLenght)
            } else {
                readOffset..<readOffset
            }

            requestId = UUID()
        }

        func waitForResult() async throws {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    final class FetchesStorage {
        let id: UUID
        let offset: Int
        let transport: any HTTPTransport
//        let startedAt: DispatchTime
//        let idleIntervalForTaskCancellation: DispatchTimeInterval

        var bytesRecieved = 0
        var bytesToLoadMax: Int?

        var lenght: Int? {
            didSet {
                if let lenght {
                    bytesUntilTaskCancelation = min(bytesUntilTaskCancelation, lenght)
                }
            }
        }// TODO: change to empty range (3..<3)
        var status: TransportStatus
        var bytesUntilTaskCancelation: Int
//        var deadlineUntilTaskCancelation: DispatchTime
        var runningFetches = [UUID: Fetch2]()

        var loadingPosition: Int {
            offset + bytesRecieved
        }

        var range: Range<Int> {
            if let lenght {
                offset..<(offset + lenght)
            } else {
                offset..<offset
            }
        }

        init(
            id: UUID,
            offset: Int,
            lenght: Int?,
            transport: any HTTPTransport,
            bytesDownloadedForTaskCancellation: Int,
//            idleIntervalForTaskCancellation: DispatchTimeInterval
        ) {
            self.id = id
            self.offset = offset
            self.lenght = lenght
            self.transport = transport
            self.bytesUntilTaskCancelation = bytesDownloadedForTaskCancellation
//            self.idleIntervalForTaskCancellation = idleIntervalForTaskCancellation

//            startedAt = .now()
            status = .pending
//            deadlineUntilTaskCancelation = .distantFuture
        }

        func canHandle(spec: DataSpec) -> Bool {
            guard offset <= spec.position else {
                return false
            }

            switch (lenght, spec.length) {
            case (let .some(lenght), .some(_)):
                let fetchRange = offset..<(offset + lenght)
                return fetchRange.contains(spec.range2)
            case (_, .none):
                return true
            case (.none, _):
                return true
            default:
                return false
            }
        }

        func updateStatus(_ transportStatus: TransportStatus) {
//            switch transportStatus {
//            case .running:
//                deadlineUntilTaskCancelation = .now().advanced(by: idleIntervalForTaskCancellation)
//            default:
//                return
//            }
        }

        func registerFetch(fetch: Fetch2) {
            runningFetches[fetch.requestId] = fetch
            if !fetch.readRange.isEmpty {
                bytesUntilTaskCancelation += fetch.readRange.count
            }
        }

        func registerBytesReceived(count: Int) {
            bytesUntilTaskCancelation -= count

            if bytesUntilTaskCancelation <= 0 && runningFetches.isEmpty {
//                print("❤️ CANCEL for request = \(range)")
//                transport.cancel()
            }

            bytesRecieved += count

//            if let bytesToLoadMax, bytesRecieved >= bytesToLoadMax  {
//                transport.cancel()
//                finishAll()
//                return
//            }

            let availableRange = offset..<(offset + bytesRecieved)
            for (id, fetch) in runningFetches {
                guard !fetch.readRange.isEmpty else { continue }

                if availableRange.contains(fetch.readRange) {
//                    print("✅ resuming fetch = \(fetch.readRange), available = \(availableRange)")
                    fetch.continuation?.resume()
                    runningFetches.removeValue(forKey: id)
                }
            }
        }

        func finishAll(with error: (any Error)? = nil) {
            print("❤️ FINISH for request = \(range)")
            runningFetches.values.forEach {
                if let error {
                    $0.continuation?.resume(throwing: error)
                } else {
                    $0.continuation?.resume()
                }
            }
            runningFetches.removeAll()
        }

        func cancelAll() {
            runningFetches.values.forEach {
                $0.continuation?.resume(throwing: CancellationError())
            }
            runningFetches.removeAll()
            transport.cancel()
        }
    }
}
