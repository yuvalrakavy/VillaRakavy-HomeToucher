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

public class PromisedQueue<T> {
    private let continuation: AsyncStream<T>.Continuation
    public let stream: AsyncStream<T>
    
    let queueName: String
    let debugLevel: Int

    public init(_ queueName: String, debugLevel: Int = 0) {
        self.queueName = queueName
        self.debugLevel = debugLevel
        
        let (stream, continuation) = AsyncStream.makeStream(of: T.self)
        self.stream = stream
        self.continuation = continuation
    }

    private func debug(_ message: String, minDebugLevel: Int = 1) {
        if self.debugLevel >= minDebugLevel {
            NSLog(message)
        }
    }

    public func send(_ item: T) {
        debug("\(queueName) Send \(item)")
        continuation.yield(item)
    }

    public func error(_ error: Error) {
        debug("\(queueName) error \(error)")
        continuation.finish()
    }
    
    public func finish() {
        debug("\(queueName) finished")
        continuation.finish()
    }
    
    public func wait() async throws -> T {
        debug("\(queueName) waiting for next item", minDebugLevel: 2)

        let waiter = Task<T, Error> {
            for await item in stream {
                return item
            }
            throw PromisedQueueError.streamFinished
        }

        return try await withTaskCancellationHandler {
            try await waiter.value
        } onCancel: {
            debug("wait on \(queueName) canceled")
            waiter.cancel()
        }
    }
    deinit {
        continuation.finish()
    }
}
