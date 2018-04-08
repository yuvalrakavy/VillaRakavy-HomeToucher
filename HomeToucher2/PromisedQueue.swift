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
    public var queue: [T] = []
    var fulfill: ((T) -> Void)? = nil
    var reject: ((Error) -> Void)? = nil
    var promise: Promise<T>?
    
    public func wait() -> Promise<T> {
        
        if self.promise == nil {
            self.promise = Promise<T>(resolver: { seal in
                self.fulfill = seal.fulfill
            })
            
            self.sendNext()
        }
        
        return self.promise!.map { v in
            self.promise = nil
            return v
        }
    }
    
    public func send(_ item: T) {
        self.queue.append(item)
        self.sendNext()
    }
    
    public func error(_ error: Error) {
        self.reject?(error)
    }
    
    private func sendNext() {
        if let resolve = self.fulfill, self.queue.count > 0 {
            let item = self.queue.removeFirst()
            
            self.fulfill = nil
            resolve(item)
        }
    }
}
