//
//  Logging.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 17.01.2026.
//

import Foundation
import os

public enum SELogLevel {
    case info
    case debug
    case error
}

public struct SELogEntry {
    public let date: Date
    public let category: LogCategory
    public let level: SELogLevel
    public let message: String
}

public protocol SELogSink: Sendable {
    func record(_ entry: SELogEntry) async
}

actor SELogSinkStore {
    static let shared = SELogSinkStore()
    private var sink: SELogSink?

    private init() {}

    func setSink(_ sink: SELogSink?) {
        self.sink = sink
    }

    func record(_ entry: SELogEntry) async {
        await sink?.record(entry)
    }
}

public enum LogCategory: String, CaseIterable, Sendable {
    case dataSource
    case extractor
    case mediaSource
    case renderLoop
    case renderer
}

public struct SELogger: Sendable {
    private static let subsystem = "com.seplayer"

    private static let loggers: [LogCategory: os.Logger] = {
        var result: [LogCategory: os.Logger] = [:]
        for category in LogCategory.allCases {
            result[category] = os.Logger(subsystem: subsystem, category: category.rawValue)
        }
        return result
    }()

    public static let enabledCategories: Set<LogCategory> = parseEnvironment()

    public static func setLogSink(_ sink: SELogSink?) {
        Task {
            await SELogSinkStore.shared.setSink(sink)
        }
    }

    public static func isEnabled(_ category: LogCategory) -> Bool {
        enabledCategories.contains(category)
    }

    public static func log(_ category: LogCategory, _ message: @autoclosure () -> String) {
        guard enabledCategories.contains(category) else { return }
        let msg = message()
        loggers[category]?.info("\(msg, privacy: .public)")
        record(category: category, level: .info, message: msg)
    }

    public static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        guard enabledCategories.contains(category) else { return }
        let msg = message()
        loggers[category]?.debug("\(msg, privacy: .public)")
        record(category: category, level: .debug, message: msg)
    }

    public static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        let msg = message()
        loggers[category]?.error("\(msg, privacy: .public)")
        record(category: category, level: .error, message: msg)
    }

    private static func record(category: LogCategory, level: SELogLevel, message: String) {
        if Task.isCancelled { return }
        Task {
            await SELogSinkStore.shared.record(SELogEntry(
                date: Date(),
                category: category,
                level: level,
                message: message
            ))
        }
    }

    private static func parseEnvironment() -> Set<LogCategory> {
        guard let envValue = ProcessInfo.processInfo.environment["SEPLAYER_LOG"] else {
            return []
        }

        let trimmed = envValue.trimmingCharacters(in: .whitespaces).lowercased()

        switch trimmed {
        case "all":
            return Set(LogCategory.allCases)
        case "none", "":
            return []
        default:
            // Parse comma-separated list
            let names = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var categories: Set<LogCategory> = []
            for name in names {
                if let category = LogCategory(rawValue: name) {
                    categories.insert(category)
                }
            }
            return categories
        }
    }
}

public extension SELogger {
    static func dataSource(_ message: @autoclosure () -> String) {
        log(.dataSource, message())
    }

    static func extractor(_ message: @autoclosure () -> String) {
        log(.extractor, message())
    }

    static func mediaSource(_ message: @autoclosure () -> String) {
        log(.mediaSource, message())
    }

    static func renderLoop(_ message: @autoclosure () -> String) {
        log(.renderLoop, message())
    }

    static func renderer(_ message: @autoclosure () -> String) {
        log(.renderer, message())
    }
}
