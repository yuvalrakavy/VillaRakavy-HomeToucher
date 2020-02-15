//
//  PromisedQueue.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 01/12/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation
import PromiseKit

public class PromisedQueue<T> {
    public enum QueueEntry {
        case Value(T)
        case Error(Error)
    }
    public var queue: [QueueEntry] = []
    
    var fulfill: ((Bool) -> Void)? = nil
    
    let queueName: String
    let debugLevel: Int
    
    init(_ queueName: String, debugLevel: Int = 0) {
        self.queueName = queueName
        self.debugLevel = debugLevel
    }
    
    private func debug(_ message: String, minDebugLevel: Int = 1) {
        if(self.debugLevel >= minDebugLevel) {
            NSLog(message)
        }
    }
    
    public func wait() -> Promise<T> {
        debug("\(queueName) Enter wait")

        func dequeueValue() -> Promise<T> {
            switch self.queue.removeFirst() {
            case .Value(let v): return Promise.value(v)
            case .Error(let e): return Promise.init(error: e)
            }
        }
        
        if !self.queue.isEmpty {
            return dequeueValue()
        }
        else {
            return Promise<Bool>(resolver: { r in
                self.fulfill = r.fulfill
            }).then { _ in
                return dequeueValue()
            }
        }
    }
    
    func signalQueue() {
        if let fulfill = self.fulfill {
            fulfill(true)
            self.fulfill = nil
        }
    }
    
    public func send(_ item: T) {
        debug("\(queueName) Send \(item)")
        self.queue.append(.Value(item))
        signalQueue()
    }
    
    public func error(_ error: Error) {
        debug("\(queueName) error \(error)")
        self.queue.append(.Error(error))
        signalQueue()
    }
}
