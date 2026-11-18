//
//  BandwidthMeter.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.05.2025.
//

import DataSource
import Foundation
import Network
import SEPlayerCommon

public protocol BandwidthMeterDelegate {

}

/// Provides estimates of the currently available bandwidth.
///
/// One meter measures the network for every player that uses it.
public protocol BandwidthMeter: AnyObject {
    var delegate: MulticastDelegate<BandwidthMeterDelegate> { get }
    var transferListener: TransferListener { get }

    /// The bitrate it is safe to plan for, in bits per second: the prediction with its safety margin, or the initial
    /// estimate until enough was measured.
    func getBitrateEstimate() -> Int

    /// The predicted bitrate of a transfer of `expectedTransferBytes`, or `nil` until enough was measured.
    ///
    /// Knowing the size of the transfer accounts for the latency of its request, which weighs more on small ones.
    func predict(expectedTransferBytes: Int?, algorithm: BandwidthPredictionAlgorithm) -> BandwidthPrediction?

    /// Transfer rates for progressive playback, in bytes per second.
    func transferRates() -> ByteTransferRates
}

public extension BandwidthMeter {
    func predict(expectedTransferBytes: Int? = nil) -> BandwidthPrediction? {
        predict(expectedTransferBytes: expectedTransferBytes, algorithm: .standard)
    }
}

/// How recent measurements weigh against older ones.
public enum BandwidthPredictionAlgorithm: Sendable {
    /// For segmented streams: a 60 s window, the last twelfth of it weighing most.
    case standard
    /// For low-latency streams: a 5 s window, weighted by the square of the age.
    case lowLatency

    var window: Int64 { Int64(self == .standard ? NSEC_PER_SEC * 60 : NSEC_PER_SEC * 5) }
}

public struct BandwidthPrediction: Sendable {
    /// The predicted bitrate, in bits per second.
    public let bitrate: Int
    /// How much of ``bitrate`` it is safe to plan for, from 0.55 to 1.
    public let safetyMultiplier: Double
    /// The deviation of the measured bitrates, in bits per second.
    public let standardDeviation: Double
    /// The deviation of the measured bitrates capped at the prediction, in bits per second.
    public let lowerStandardDeviation: Double

    /// The bitrate it is safe to plan for, in bits per second.
    public var safeBitrate: Int { max(1, Int(Double(bitrate) * safetyMultiplier)) }
}

/// Transfer rates as progressive playback measures them, in bytes per second. Zero means not measured yet.
public struct ByteTransferRates: Sendable {
    public let average: Double
    public let movingAverage: Double
    public let standardDeviation: Double
}

/// Estimates bandwidth from the network activity of the transfers it hears.
///
/// The prediction is a weighted mean of the bitrates of 100 ms samples, weighted by the time they were delivering, the
/// size of their responses, and how recent they are. Its safety margin comes from how much the bitrates of 1 s samples
/// vary.
///
/// What was measured on one network says little about another, so the meter forgets it when the device moves between
/// Wi-Fi, cellular and wired networks.
final class DefaultBandwidthMeter: BandwidthMeter, @unchecked Sendable {
    /// The initial estimate, before transfers were measured.
    static let defaultInitialBitrateEstimate = 1_000_000
    /// Enough was measured once this much was received, or ``minimumActiveTime`` passed.
    private static let minimumBytes = 262_144.0
    private static let minimumActiveTime = Int64(NSEC_PER_SEC)
    private static let varianceResolution = Int64(NSEC_PER_SEC)

    let delegate = MulticastDelegate<BandwidthMeterDelegate>(isThreadSafe: true)
    var transferListener: TransferListener { self }

    private let lock = UnfairLock()
    private let initialBitrateEstimate: Int
    // All guarded by lock.
    private var history = NetworkHistory()
    private var byteRates = ByteRateHistory()
    /// Requests delivering bytes, for the delivery time of the byte rates.
    private var deliveringRequests = Set<UInt64>()
    private var lastDeliveryProgress: UInt64?
    /// The kind of network the measurements come from.
    private var network: NetworkKind?

    private let pathMonitor = NWPathMonitor()

    init(initialBitrateEstimate: Int = DefaultBandwidthMeter.defaultInitialBitrateEstimate) {
        self.initialBitrateEstimate = initialBitrateEstimate
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.networkChanged(to: NetworkKind(path))
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.seplayer.bandwidthMeter.path", qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
    }

    func getBitrateEstimate() -> Int {
        predict(expectedTransferBytes: nil, algorithm: .standard)?.safeBitrate ?? initialBitrateEstimate
    }

    func predict(expectedTransferBytes: Int?, algorithm: BandwidthPredictionAlgorithm) -> BandwidthPrediction? {
        predict(expectedTransferBytes: expectedTransferBytes, algorithm: algorithm, at: DispatchTime.now())
    }

    /// The prediction at `time`, which the measurements age from.
    func predict(
        expectedTransferBytes: Int?,
        algorithm: BandwidthPredictionAlgorithm,
        at time: DispatchTime
    ) -> BandwidthPrediction? {
        let now = Int64(clamping: time.uptimeNanoseconds)
        return lock.withLock {
            Self.predict(history: history, now: now, expectedTransferBytes: expectedTransferBytes, algorithm: algorithm)
        }
    }

    func transferRates() -> ByteTransferRates {
        lock.withLock {
            let rates = byteRates.rates
            return ByteTransferRates(
                average: rates.average,
                movingAverage: rates.movingAverage,
                standardDeviation: rates.standardDeviation
            )
        }
    }

    /// Forgets what was measured, as when the network changes.
    func reset() {
        lock.withLock {
            history.reset()
            byteRates.reset()
            deliveringRequests.removeAll()
            lastDeliveryProgress = nil
        }
    }

    /// Resets on a move from one kind of network to another. A path without a network, or with one of another kind,
    /// as a VPN alone, doesn't count: measurements stay until a network of a known kind replaces the last one.
    private func networkChanged(to kind: NetworkKind?) {
        guard let kind else { return }
        let previous = lock.withLock {
            defer { network = kind }
            return network
        }
        guard let previous, previous != kind else { return }
        SELogger.debug(.bandwidth, "Network changed from \(previous) to \(kind): reset")
        reset()
    }

    private func add(_ event: NetworkTransferEvent) {
        lock.withLock {
            history.add(event)
            updateByteRates(with: event)
        }
        if case .requestEnded = event.kind {
            SELogger.debug(.bandwidth, "Request \(event.requestId) ended: estimate \(getBitrateEstimate() / 1000) kbit/s")
        }
    }

    /// Byte rates count the time some request was delivering, once for concurrent ones.
    private func updateByteRates(with event: NetworkTransferEvent) {
        if let last = lastDeliveryProgress, !deliveringRequests.isEmpty, event.time > last {
            byteRates.add(bytes: 0, duration: Int64(event.time - last))
        }
        lastDeliveryProgress = event.time

        switch event.kind {
        case .requestSent:
            break
        case .responseReceived:
            deliveringRequests.insert(event.requestId)
        case let .bytesReceived(count):
            deliveringRequests.insert(event.requestId)
            byteRates.add(bytes: Int64(count), duration: 0)
        case .requestEnded:
            deliveringRequests.remove(event.requestId)
        }
    }
}

extension DefaultBandwidthMeter: TransferListener {
    func onTransferInitializing(source: DataSource, isNetwork: Bool) {}

    func onTransferEnd(source: DataSource, isNetwork: Bool, metrics: URLSessionTaskMetrics) {}

    func onNetworkTransfer(_ event: NetworkTransferEvent) {
        add(event)
    }
}

extension DefaultBandwidthMeter {
    /// The weighted mean and variance, updated one value at a time.
    private struct Moments {
        var weight = 0.0
        var mean = 0.0
        var squaredDeviations = 0.0

        mutating func add(_ value: Double, weight addedWeight: Double) {
            guard addedWeight > 0 else { return }
            weight += addedWeight
            let delta = value - mean
            mean += delta * addedWeight / weight
            squaredDeviations += addedWeight * delta * (value - mean)
        }

        var standardDeviation: Double {
            weight > .ulpOfOne && squaredDeviations > .ulpOfOne ? (squaredDeviations / weight).squareRoot() : 0
        }
    }

    static func predict(
        history: NetworkHistory,
        now: Int64,
        expectedTransferBytes: Int?,
        algorithm: BandwidthPredictionAlgorithm
    ) -> BandwidthPrediction? {
        guard let end = history.lastActiveTime(now: now) else { return nil }
        let start = end - algorithm.window

        // First pass: the prediction, from the finest samples.
        let samples = history.samples(from: start, to: end, resolution: NetworkHistory.resolution, now: now)
        let bytes = samples.reduce(0) { $0 + $1.bytes }
        let activeTime = samples.reduce(0) { $0 + $1.activeTime }
        guard bytes >= minimumBytes || activeTime >= minimumActiveTime else {
            return nil
        }

        var moments = Moments()
        for sample in samples {
            moments.add(sample.bitrate, weight: weight(of: sample, start: start, end: end, algorithm: algorithm))
        }
        guard moments.mean.isFinite, moments.mean > 0 else { return nil }

        var bitrate = moments.mean
        if let expectedTransferBytes, expectedTransferBytes > 0,
           let latency = history.medianLatency(from: start, to: end) {
            // Half of the latency is spent before the transfer: it weighs more on small transfers.
            let bits = Double(expectedTransferBytes) * 8
            bitrate = bits / (Double(latency / 2) / 1e9 + bits / bitrate)
        }
        bitrate = bitrate.rounded(.toNearestOrAwayFromZero)
        guard bitrate.isFinite, bitrate >= 1 else { return nil }

        // Second pass, at a coarser resolution: how much the bitrate varies, also when capped at the prediction.
        var variance = Moments()
        var lowerVariance = Moments()
        let coarseSamples = history.samples(from: start, to: end, resolution: varianceResolution, now: now)
        for sample in coarseSamples {
            let weight = weight(of: sample, start: start, end: end, algorithm: algorithm)
            variance.add(sample.bitrate, weight: weight)
            lowerVariance.add(min(sample.bitrate, bitrate), weight: weight)
        }

        let deviation = variance.standardDeviation
        let lowerDeviation = lowerVariance.standardDeviation
        let multiplier: Double = if lowerDeviation > .ulpOfOne {
            1 - lowerDeviation / bitrate
        } else if deviation > .ulpOfOne {
            1 - deviation / bitrate
        } else {
            0.9
        }

        return BandwidthPrediction(
            bitrate: bitrate >= Double(Int.max) ? Int.max : Int(bitrate),
            safetyMultiplier: min(1, max(0.55, multiplier)),
            standardDeviation: deviation,
            lowerStandardDeviation: lowerDeviation
        )
    }

    private static func weight(
        of sample: NetworkHistory.Sample,
        start: Int64,
        end: Int64,
        algorithm: BandwidthPredictionAlgorithm
    ) -> Double {
        let timeWeight: Double
        switch algorithm {
        case .standard:
            let position = Double(sample.end - start) / Double(end - start)
            timeWeight = 10_000_000 / (1 + exp(-25 * (position - 11.0 / 12.0)))
        case .lowLatency:
            let age = Double(sample.end - start) / 1e9
            timeWeight = age * age
        }
        let sizeWeight = max(1, (sample.responseSize / 1024).rounded(.down))
        return max(0, timeWeight * sizeWeight) * Double(sample.activeTime)
    }
}

/// The kind of network transfers go over.
private enum NetworkKind: CustomStringConvertible {
    case wifi
    case cellular
    case wired

    /// The kind of the interface the path prefers, nil without a network or for other kinds.
    init?(_ path: NWPath) {
        guard path.status == .satisfied else { return nil }
        if path.usesInterfaceType(.wifi) {
            self = .wifi
        } else if path.usesInterfaceType(.cellular) {
            self = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            self = .wired
        } else {
            return nil
        }
    }

    var description: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .cellular: "cellular"
        case .wired: "wired"
        }
    }
}
