//
//  SEPlayerTaskQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.01.2025.
//

import Foundation

protocol SEPlayerTaskDelegate: AnyObject {
    func didFinishTask(_ task: SEPlayerTask, error: Error?)
}

class SEPlayerTask {
    weak var taskDelegate: SEPlayerTaskDelegate?

    var isCancelled: Bool = false
    var completionBlock: (() -> Void)?

    func cancel() {
        isCancelled = true
    }

    func execute() {
        assertionFailure("To override")
    }

    func finish(error: Error? = nil) {
        taskDelegate?.didFinishTask(self, error: error)
    }
}

final class SEPlayerTaskQueue {
    private(set) var isRunning = false
    private(set) var isSuspended = false

    let timer: DispatchSourceTimer

    private let queue: Queue

    private var tasksQueue: [SEPlayerTask] = [] {
        didSet {
            if tasksQueue.isEmpty {
                suspendTimer()
            } else {
                resumeTimer()
            }
        }
    }

    private var isTimerRunning: Bool = false
    private var currentTask: SEPlayerTask?

    var tasks: [SEPlayerTask] {
        var result = tasksQueue
        if let currentTask {
            result.insert(currentTask, at: 0)
        }
        return result
    }

    init(queue: Queue) {
        self.queue = queue
        self.timer = DispatchSource.makeTimerSource(flags: .strict,queue: queue.queue)
        prepareTimer()
    }

    func addTask(_ task: SEPlayerTask) {
        tasksQueue.append(task)
    }
 
    func doNextTask() {
//        performNextTask()
    }

    func start() {
        isSuspended = false
    }

    func stop() {
        isSuspended = true
    }

    private func performNextTask() {
        guard !tasksQueue.isEmpty, !isSuspended, !isRunning else { return }
        isRunning = true

        let task = tasksQueue.removeFirst()
        if task.isCancelled {
            task.completionBlock?()
            task.completionBlock = nil
            isRunning = false
            performNextTask()
        }

        currentTask = task
        task.taskDelegate = self
        task.execute()
    }
}

extension SEPlayerTaskQueue: SEPlayerTaskDelegate {
    func didFinishTask(_ task: SEPlayerTask, error: Error?) {
        task.completionBlock?()
        task.completionBlock = nil
        currentTask = nil
        isRunning = false
//        performNextTask()
    }
}

private extension SEPlayerTaskQueue {
    func prepareTimer() {
        timer.setEventHandler { [weak self] in
            self?.performNextTask()
        }

        let timeout: Double = 1 / 60
        let time = DispatchTime.now() + timeout
        timer.schedule(deadline: time, repeating: timeout)
    }

    func resumeTimer() {
        guard !isTimerRunning else { return }
        isTimerRunning = true
        timer.resume()
    }
    
    func suspendTimer() {
        guard isTimerRunning else { return }
        isTimerRunning = false
        timer.suspend()
    }
}
