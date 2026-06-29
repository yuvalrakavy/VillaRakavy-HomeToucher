//
//  PromisedQueue.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 01/12/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation

public enum PromisedQueueError: Error {
    case streamFinished
}

/// A single-consumer async channel.
///
/// `send` is synchronous and ordered — required by the network read path, which
/// hands raw input buffers from the main-thread stream delegate to the reader
/// task. Values sent with no waiter are buffered and delivered in order.
///
/// Cancelling a `wait()` resumes ONLY that caller (with `CancellationError`) and
/// leaves the queue fully usable. The previous AsyncStream-based implementation
/// created a fresh iterator per `wait()`, and cancelling one `wait()` called
/// `terminate(.cancelled)` on the shared stream — permanently finishing the queue
/// for every future caller (a latching "dropped signal / frozen" bug). This
/// implementation has no such failure mode (verified: a cancelled wait does not
/// affect subsequent waits).
///
/// State is lock-protected, so the queue is safe to share across isolation
/// domains (`@unchecked Sendable`); `send`/`wait` use `sending` so non-Sendable
/// payloads (input buffers, NetService) can be transferred under Swift 6.
public final class PromisedQueue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [T] = []
    private var waiter: CheckedContinuation<T, Error>?
    private var isTerminated = false
    private var terminalError: Error?

    let queueName: String
    let debugLevel: Int

    public init(_ queueName: String, debugLevel: Int = 0) {
        self.queueName = queueName
        self.debugLevel = debugLevel
    }

    private func debug(_ message: String, minDebugLevel: Int = 1) {
        if debugLevel >= minDebugLevel {
            NSLog(message)
        }
    }

    public func send(_ item: sending T) {
        lock.lock()
        if isTerminated {
            lock.unlock()
            return
        }
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: item)   // resume outside the lock
        } else {
            buffer.append(item)
            lock.unlock()
        }
    }

    public func error(_ error: Error) {
        debug("\(queueName) error \(error)")
        terminate(with: error)
    }

    public func finish() {
        debug("\(queueName) finished")
        terminate(with: PromisedQueueError.streamFinished)
    }

    private func terminate(with error: Error) {
        lock.lock()
        if isTerminated {
            lock.unlock()
            return
        }
        isTerminated = true
        terminalError = error
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: error)
    }

    public func wait() async throws -> sending T {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                lock.lock()

                // Deliver a buffered value first, preserving send order.
                if !buffer.isEmpty {
                    let item = buffer.removeFirst()
                    lock.unlock()
                    cont.resume(returning: item)
                    return
                }
                if isTerminated {
                    let err = terminalError ?? PromisedQueueError.streamFinished
                    lock.unlock()
                    cont.resume(throwing: err)
                    return
                }
                // Single-consumer contract: at most one outstanding wait().
                if waiter != nil {
                    lock.unlock()
                    cont.resume(throwing: PromisedQueueError.streamFinished)
                    return
                }
                // Already-cancelled fast path.
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiter = cont
                lock.unlock()
            }
        } onCancel: {
            // Resume only this waiter; the queue stays alive for future waits.
            lock.lock()
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(throwing: CancellationError())
        }
    }

    deinit {
        // Don't leak a parked waiter if the queue is torn down.
        waiter?.resume(throwing: PromisedQueueError.streamFinished)
    }
}
