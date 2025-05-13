//
//  AsyncOperation.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.05.2025.
//

import Foundation

class AsyncOperation: Operation, @unchecked Sendable {
    private enum OperationChangeKey: String {
        case isExecuting
        case isFinished
    }

    public typealias FinishHandler = () -> Void

    private let completion: () -> Void

    public init(completion: @escaping () -> Void) {
        self.completion = completion
        super.init()
    }

    open func work(_ finish: @escaping () -> Void) {
        assertionFailure("Subclasses must override without calling super.")
    }

    open override func start() {
        guard !isCancelled else {
            markAsFinished()
            return
        }
        running(task: {
            self.work {
                if !self.isCancelled { self.completion() }
                self.markAsFinished()
            }
        })
    }

    open override func cancel() {
        super.cancel()
        guard isExecuting else { return }
        markAsFinished()
    }

    private var _executing: Bool = false
    open override var isExecuting: Bool {
        get { _executing }
        set { _executing = newValue }
    }

    private var _finished: Bool = false
    open override var isFinished: Bool {
        get { _finished }
        set { _finished = newValue }
    }

    open override var isAsynchronous: Bool {
        true
    }

    private func running(task: @escaping () -> Void) {
        willChangeValue(for: .isExecuting)
        task()
        _executing = true
        didChangeValue(for: .isExecuting)
    }

    private func markAsFinished() {
        willChangeValue(for: .isExecuting)
        willChangeValue(for: .isFinished)
        _executing = false
        _finished = true
        didChangeValue(for: .isExecuting)
        didChangeValue(for: .isFinished)
    }

    private func willChangeValue(for key: OperationChangeKey) {
        willChangeValue(forKey: key.rawValue)
    }

    private func didChangeValue(for key: OperationChangeKey) {
        didChangeValue(forKey: key.rawValue)
    }
}
