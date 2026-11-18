//
//  NetworkHistory.swift
//  SEPlayer
//

import DataSource

/// The recent network activity of the player, as the bandwidth prediction reads it: bytes received over time, the
/// time some request was delivering them, and how long requests waited for their responses.
///
/// Bytes are spread over the time since the previous bytes of their
/// request, and time counts as active only while some
/// request is delivering, counted once for concurrent requests. Idle time between requests is not network time.
///
/// A response delivered faster than ``minimumMeasurableDelivery`` can't be timed: a small one comes in a burst, and
/// its bytes may already be waiting when its headers are seen. Its bytes count as delivered over that minimum, ending
/// when the last of them came, but not from before the request was sent: a bound the network did at least as well
/// as, not a rate it never had.
///
/// Not thread safe: guarded by its owner.
struct NetworkHistory {
    /// One measured interval of the history.
    struct Sample {
        /// End of the interval, in nanoseconds.
        let end: Int64
        /// Bytes received in the interval.
        let bytes: Double
        /// Time some request was delivering, in nanoseconds.
        let activeTime: Int64
        /// The size of the responses the bytes belong to, weighted by their bytes.
        let responseSize: Double

        /// In bits per second.
        var bitrate: Double { 8 * bytes / (Double(activeTime) / 1e9) }
    }

    /// The finest resolution samples are kept at, in nanoseconds.
    static let resolution: Int64 = 100_000_000
    /// The shortest delivery a response is timed by, in nanoseconds.
    static let minimumMeasurableDelivery: Int64 = 20_000_000
    /// How far back the history goes, in nanoseconds.
    let maxAge: Int64

    private struct Request {
        let sentAt: Int64
        var deliveringSince: Int64?
        var lastBytesAt: Int64?
        var expectedBytes: Int?
        var receivedBytes = 0
        /// Bytes that don't count yet: the delivery is too short so far to time.
        var pendingBytes = 0
        var isMeasurable = false

        var size: Double { Double(max(expectedBytes ?? 0, receivedBytes)) }
    }

    fileprivate struct Bin {
        var bytes = 0.0
        var responseSizeTimesBytes = 0.0
    }

    private var requests: [UInt64: Request] = [:]
    /// Ended intervals in which requests were delivering, in the order they ended.
    private var deliveryIntervals: [(start: Int64, end: Int64)] = []
    private var bins: [Int64: Bin] = [:]
    /// Time from sending a request to its response, in nanoseconds, with when the response came.
    private var latencies: [(time: Int64, latency: Int64)] = []
    private var lastActivity: Int64?

    init(maxAge: Int64 = 61_000_000_000) {
        self.maxAge = maxAge
    }

    var isEmpty: Bool { bins.isEmpty }

    mutating func reset() {
        requests.removeAll()
        deliveryIntervals.removeAll()
        bins.removeAll()
        latencies.removeAll()
        lastActivity = nil
    }

    mutating func add(_ event: NetworkTransferEvent) {
        let time = Int64(clamping: event.time)
        switch event.kind {
        case .requestSent:
            requests[event.requestId] = Request(sentAt: time)
        case let .responseReceived(expectedBytes):
            guard var request = requests[event.requestId] else { return }
            request.deliveringSince = time
            request.expectedBytes = expectedBytes
            requests[event.requestId] = request
            latencies.append((time, max(0, time - request.sentAt)))
        case let .bytesReceived(count):
            guard var request = requests[event.requestId], count > 0 else {
                return
            }
            if request.deliveringSince == nil { request.deliveringSince = time }
            let since = request.deliveringSince ?? time
            let from = request.lastBytesAt ?? since
            request.receivedBytes += count
            request.lastBytesAt = time
            if request.isMeasurable {
                spread(bytes: Double(count), responseSize: request.size, from: from, to: time)
                lastActivity = time
            } else if time - since >= Self.minimumMeasurableDelivery {
                // Long enough now: what came so far counts over the whole delivery.
                request.isMeasurable = true
                spread(bytes: Double(request.pendingBytes + count), responseSize: request.size, from: since, to: time)
                request.pendingBytes = 0
                lastActivity = time
            } else {
                request.pendingBytes += count
            }
            requests[event.requestId] = request
        case .requestEnded:
            guard let request = requests.removeValue(forKey: event.requestId) else {
                return
            }
            if !request.isMeasurable, request.pendingBytes > 0, let lastBytesAt = request.lastBytesAt {
                // A burst: over the minimum delivery that ended with its last bytes.
                let start = max(request.sentAt, lastBytesAt - Self.minimumMeasurableDelivery)
                if lastBytesAt > start {
                    spread(bytes: Double(request.pendingBytes), responseSize: request.size, from: start, to: lastBytesAt)
                    deliveryIntervals.append((start, lastBytesAt))
                    lastActivity = max(lastActivity ?? lastBytesAt, lastBytesAt)
                }
            } else if let start = request.deliveringSince {
                // A request that delivered nothing still kept the network busy while it waited for bytes.
                let end = max(start, request.lastBytesAt ?? time)
                if end > start {
                    deliveryIntervals.append((start, end))
                    lastActivity = max(lastActivity ?? end, end)
                }
            }
        }
        prune(now: time)
    }

    /// The last time a request was delivering: `now` while one is.
    func lastActiveTime(now: Int64) -> Int64? {
        requests.values.contains { $0.deliveringSince != nil } ? now : lastActivity
    }

    /// The samples of `start..<end`, at `resolution` (a multiple of ``resolution``), leaving out those without
    /// activity.
    func samples(from start: Int64, to end: Int64, resolution: Int64, now: Int64) -> [Sample] {
        guard end > start else { return [] }
        let resolution = max(Self.resolution, resolution)

        // The delivery time of every interval, counted once where requests overlap.
        var intervals = deliveryIntervals.filter { $0.end > start && $0.start < end }
        for request in requests.values {
            guard let since = request.deliveringSince, now > since else {
                continue
            }
            if request.isMeasurable || now - since >= Self.minimumMeasurableDelivery {
                intervals.append((since, now))
            }
        }
        intervals.sort { $0.start < $1.start }
        var merged: [(start: Int64, end: Int64)] = []
        for interval in intervals {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }

        var activeByBin: [Int64: Int64] = [:]
        for interval in merged {
            var from = max(interval.start, start)
            let to = min(interval.end, end)
            while from < to {
                let bin = floorDiv(from, resolution)
                let binEnd = min((bin + 1) * resolution, to)
                activeByBin[bin, default: 0] += binEnd - from
                from = binEnd
            }
        }

        var bytesByBin: [Int64: Bin] = [:]
        for (fineBin, value) in bins {
            let binStart = fineBin * Self.resolution
            guard binStart + Self.resolution > start, binStart < end else {
                continue
            }
            let bin = floorDiv(binStart, resolution)
            bytesByBin[bin, default: Bin()].bytes += value.bytes
            bytesByBin[bin, default: Bin()].responseSizeTimesBytes += value.responseSizeTimesBytes
        }

        return activeByBin.keys.sorted().compactMap { bin in
            guard let active = activeByBin[bin], active > 0 else { return nil }
            let value = bytesByBin[bin] ?? Bin()
            return Sample(
                end: min((bin + 1) * resolution, end),
                bytes: value.bytes,
                activeTime: active,
                responseSize: value.bytes > 0 ? value.responseSizeTimesBytes / value.bytes : 0
            )
        }
    }

    /// The median time to a response, of the responses in `start..<end`, in nanoseconds.
    func medianLatency(from start: Int64, to end: Int64) -> Int64? {
        let values = latencies.filter { $0.time >= start && $0.time <= end }.map(\.latency).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count % 2 == 0 ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    /// Spreads bytes over the time they took to arrive, in proportion to the overlap with each bin.
    private mutating func spread(bytes: Double, responseSize: Double, from: Int64, to: Int64) {
        guard to > from else {
            bins[floorDiv(to, Self.resolution), default: Bin()].add(bytes: bytes, responseSize: responseSize)
            return
        }
        var position = from
        let duration = Double(to - from)
        while position < to {
            let bin = floorDiv(position, Self.resolution)
            let binEnd = min((bin + 1) * Self.resolution, to)
            let share = bytes * Double(binEnd - position) / duration
            bins[bin, default: Bin()].add(bytes: share, responseSize: responseSize)
            position = binEnd
        }
    }

    private mutating func prune(now: Int64) {
        let oldest = now - maxAge
        let oldestBin = floorDiv(oldest, Self.resolution)
        bins = bins.filter { $0.key >= oldestBin }
        deliveryIntervals.removeAll { $0.end < oldest }
        latencies.removeAll { $0.time < oldest }
        // A request that has said nothing for longer than the history is lost.
        requests = requests.filter { ($0.value.lastBytesAt ?? $0.value.deliveringSince ?? $0.value.sentAt) >= oldest }
    }

    private func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        value >= 0 ? value / divisor : (value - divisor + 1) / divisor
    }
}

private extension NetworkHistory.Bin {
    mutating func add(bytes: Double, responseSize: Double) {
        self.bytes += bytes
        responseSizeTimesBytes += bytes * responseSize
    }
}
