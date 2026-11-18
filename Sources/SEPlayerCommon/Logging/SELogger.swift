//
//  SELogger.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import Foundation
import os

/// A part of the playback pipeline, whose logs are switched on and off together.
public enum SELogDomain: String, CaseIterable, Sendable {
    /// Loading bytes: HTTP requests, the cache, files, decryption.
    case dataSource
    /// Turning bytes into samples: containers and their tracks.
    case extractor
    /// Media periods: progressive and HLS loading, playlists, sample queues.
    case mediaSource
    /// The player: playback state, seeks, periods, buffering decisions, track selection, the clock.
    case player
    /// Renderers: their lifecycle, decoding, output, synchronization and recovery.
    case renderer
}

/// A topic of the logs. Each belongs to one domain, and can be switched on and off apart from the others of its domain.
public enum SELogTopic: String, CaseIterable, Sendable {
    /// Data source
    /// HTTP requests, responses and downloads.
    case http
    /// The byte cache: blocks, eviction, memory the system took back, the budget.
    case cache
    /// The storage cache: entries, blocks written and read, eviction, limits.
    case diskCache
    /// Local files.
    case file
    /// Loading ahead of the reads.
    case readAhead
    /// Decryption of encrypted segments.
    case decryption

    /// Extractor
    /// Choosing an extractor for the data.
    case sniffing
    /// MP4 and fragmented MP4.
    case mp4
    /// MPEG transport streams.
    case transportStream
    /// Subtitle files.
    case subtitles

    /// Media source
    /// Progressive media: loading, the extraction window, seeks.
    case progressive
    /// HLS loading: chunks, variants, I-frames, scrubbing.
    case hls
    /// HLS playlists: loads, refreshes, errors.
    case playlist
    /// Sample queues: formats, discarding, splicing.
    case sampleQueue
    /// Loads, retries and cancellations.
    case loader

    /// Player
    /// Playback state and play/pause.
    case playback
    /// Seeks: requests, coalescing, completion.
    case seek
    /// Media periods: preparation, transitions, the queue.
    case periods
    /// Whether to load, and when playback can start.
    case loadControl
    /// Bandwidth estimates.
    case bandwidth
    /// Track selection and adaptive bitrate switches.
    case trackSelection
    /// The playback clock and time sources.
    case clock
    /// What the player tells its delegates.
    case events
    /// The app's audio session: its setup, interruptions, routes.
    case audioSession
    /// Each piece of work the player runs on its queue, in the order it runs. Verbose only, and off unless switched on:
    /// it logs every event the player handles.
    case scheduling

    /// Renderer
    /// Renderer lifecycle: enabling, starting, stopping, resets, stream changes, readiness.
    case lifecycle
    /// Audio renderers.
    case audio
    /// Video renderers.
    case video
    /// Text renderers.
    case text
    /// Decoders: sessions, formats, failures.
    case decoder
    /// Display layers and outputs.
    case display
    /// Renderer synchronization and timers.
    case sync
    /// Recovering from renderer failures.
    case recovery

    public var domain: SELogDomain {
        switch self {
        case .http,
             .cache,
             .diskCache,
             .file,
             .readAhead,
             .decryption: .dataSource
        case .sniffing,
             .mp4,
             .transportStream,
             .subtitles: .extractor
        case .progressive,
             .hls,
             .playlist,
             .sampleQueue,
             .loader: .mediaSource
        case .playback,
             .seek,
             .periods,
             .loadControl,
             .bandwidth,
             .trackSelection,
             .clock,
             .events,
             .audioSession,
             .scheduling: .player
        case .lifecycle,
             .audio,
             .video,
             .text,
             .decoder,
             .display,
             .sync,
             .recovery: .renderer
        }
    }

    public static func topics(of domain: SELogDomain) -> [SELogTopic] {
        allCases.filter { $0.domain == domain }
    }
}

/// How important a message is.
public enum SELogLevel: Int, Comparable, CaseIterable, Sendable {
    /// Something failed.
    case error = 1
    /// Something unexpected that playback goes on from.
    case warning
    /// A notable event: a state change, a request, a decision.
    case info
    /// Details of what happens: values the decisions were made with.
    case debug
    /// Everything, as each sample or each piece of data.
    case verbose

    public static func < (lhs: SELogLevel, rhs: SELogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The most detailed level that is logged, or none.
public enum SELogVerbosity: Int, Comparable, CaseIterable, Sendable {
    case off = 0
    case error
    case warning
    case info
    case debug
    case verbose

    public init(_ level: SELogLevel) {
        self = SELogVerbosity(rawValue: level.rawValue) ?? .verbose
    }

    public static func < (lhs: SELogVerbosity, rhs: SELogVerbosity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A logged message, for a ``SELogSink``.
public struct SELogEntry: Sendable {
    public let date: Date
    public let topic: SELogTopic
    public let level: SELogLevel
    public let message: String

    public var domain: SELogDomain { topic.domain }
}

/// Receives the logged messages, besides the system log. Called on the thread that logs.
public protocol SELogSink: AnyObject, Sendable {
    func record(_ entry: SELogEntry)
}

/// The logs of the player, by domain and topic.
///
/// Each domain has a verbosity, and a topic can override the verbosity of its domain:
///
/// ```swift
/// SELogger.setVerbosity(.debug, for: .renderer)   // all renderer topics
/// SELogger.setVerbosity(.off, for: .dataSource)
/// SELogger.setVerbosity(.verbose, for: .http)      // one topic of the data source
/// ```
///
/// Errors of every domain are logged until configured otherwise. The `SEPLAYER_LOG` environment variable sets the
/// verbosities at launch, as comma-separated `name=verbosity` pairs, where a name is a domain, a topic or `all`, and
/// a verbosity is `off`, `error`, `warning`, `info`, `debug` or `verbose`; a name alone means `info`:
/// `SEPLAYER_LOG="all=error,renderer=debug,dataSource=off,hls"`. With `SEPLAYER_LOG_PRINT=1` the messages are printed
/// too, as for runs from the command line.
///
/// Messages go to the system log under the subsystem `com.seplayer`, with the category `domain.topic`, such as
/// `renderer.video`. A message is only made when its topic logs its level.
public enum SELogger {
    public static let subsystem = "com.seplayer"

    // MARK: - Configuration

    /// Sets how much a domain logs, for its topics without a verbosity of their own.
    public static func setVerbosity(_ verbosity: SELogVerbosity, for domain: SELogDomain) {
        configuration.withLock { $0.domains[domain] = verbosity }
    }

    /// Sets how much a topic logs, whatever its domain logs. `nil` makes it follow its domain again.
    public static func setVerbosity(_ verbosity: SELogVerbosity?, for topic: SELogTopic) {
        configuration.withLock { $0.topics[topic] = verbosity }
    }

    /// Sets how much every domain logs, and makes every topic follow its domain.
    public static func setVerbosity(_ verbosity: SELogVerbosity) {
        configuration.withLock {
            for domain in SELogDomain.allCases { $0.domains[domain] = verbosity }
            $0.topics.removeAll()
        }
    }

    /// How much a topic logs now.
    public static func verbosity(for topic: SELogTopic) -> SELogVerbosity {
        configuration.withLock { $0.verbosity(for: topic) }
    }

    /// Whether a message of `level` about `topic` is logged.
    public static func isEnabled(_ topic: SELogTopic, _ level: SELogLevel) -> Bool {
        configuration.withLock { $0.verbosity(for: topic) >= SELogVerbosity(level) }
    }

    /// Receives the messages besides the system log, or `nil` for none.
    public static func setSink(_ sink: SELogSink?) {
        configuration.withLock { $0.sink = sink }
    }

    /// Whether the messages are printed to the standard output too.
    public static func setPrintsMessages(_ printsMessages: Bool) {
        configuration.withLock { $0.printsMessages = printsMessages }
    }

    // MARK: - Logging

    public static func error(_ topic: SELogTopic, _ message: @autoclosure () -> String) {
        log(topic, .error, message)
    }

    public static func warning(_ topic: SELogTopic, _ message: @autoclosure () -> String) {
        log(topic, .warning, message)
    }

    public static func info(_ topic: SELogTopic, _ message: @autoclosure () -> String) {
        log(topic, .info, message)
    }

    public static func debug(_ topic: SELogTopic, _ message: @autoclosure () -> String) {
        log(topic, .debug, message)
    }

    public static func verbose(_ topic: SELogTopic, _ message: @autoclosure () -> String) {
        log(topic, .verbose, message)
    }

    public static func log(_ topic: SELogTopic, _ level: SELogLevel, _ message: @autoclosure () -> String) {
        log(topic, level, message)
    }

    private static func log(_ topic: SELogTopic, _ level: SELogLevel, _ message: () -> String) {
        let (isEnabled, sink, printsMessages) = configuration.withLock {
            ($0.verbosity(for: topic) >= SELogVerbosity(level), $0.sink, $0.printsMessages)
        }
        guard isEnabled else { return }

        let text = message()
        let logger = loggers[topic]
        switch level {
        case .error: logger?.error("\(text, privacy: .public)")
        case .warning: logger?.notice("\(text, privacy: .public)")
        case .info: logger?.info("\(text, privacy: .public)")
        case .debug,
             .verbose: logger?.debug("\(text, privacy: .public)")
        }

        if printsMessages {
            print(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime)
                + "[\(topic.domain.rawValue).\(topic.rawValue)] \(level.symbol) \(text)")
        }
        sink?.record(SELogEntry(date: Date(), topic: topic, level: level, message: text))
    }

    // MARK: - State

    fileprivate struct Configuration {
        var domains: [SELogDomain: SELogVerbosity]
        var topics: [SELogTopic: SELogVerbosity] = [:]
        var sink: SELogSink?
        var printsMessages = false

        func verbosity(for topic: SELogTopic) -> SELogVerbosity {
            topics[topic] ?? domains[topic.domain] ?? .error
        }
    }

    private static let configuration = ConfigurationStore(makeConfiguration(environment: ProcessInfo.processInfo.environment))

    private static let loggers: [SELogTopic: os.Logger] = Dictionary(uniqueKeysWithValues: SELogTopic.allCases.map {
        ($0, os.Logger(subsystem: subsystem, category: "\($0.domain.rawValue).\($0.rawValue)"))
    })

    private static func makeConfiguration(environment: [String: String]) -> Configuration {
        var configuration = Configuration(domains: Dictionary(uniqueKeysWithValues: SELogDomain.allCases.map { ($0, .error) }))
        configuration.printsMessages = ["1", "yes", "true"].contains(environment["SEPLAYER_LOG_PRINT"]?.lowercased() ?? "")

        for item in (environment["SEPLAYER_LOG"] ?? "").split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { continue }
            let verbosity = parts.count > 1 ? SELogVerbosity(name: parts[1]) : .info
            guard let verbosity else { continue }

            if name.lowercased() == "all" {
                for domain in SELogDomain.allCases { configuration.domains[domain] = verbosity }
                configuration.topics.removeAll()
            } else if let domain = SELogDomain.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
                configuration.domains[domain] = verbosity
            } else if let topic = SELogTopic.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
                configuration.topics[topic] = verbosity
            }
        }
        return configuration
    }
}

/// The configuration, behind a lock: logging happens on any thread.
private final class ConfigurationStore: @unchecked Sendable {
    private let lock = UnfairLock()
    private var value: SELogger.Configuration

    init(_ value: SELogger.Configuration) {
        self.value = value
    }

    func withLock<R>(_ body: (inout SELogger.Configuration) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private extension SELogVerbosity {
    init?(name: String) {
        guard let verbosity = SELogVerbosity.allCases.first(where: { "\($0)" == name.lowercased() }) else {
            return nil
        }
        self = verbosity
    }
}

private extension SELogLevel {
    var symbol: String {
        switch self {
        case .error: "E"
        case .warning: "W"
        case .info: "I"
        case .debug: "D"
        case .verbose: "V"
        }
    }
}
